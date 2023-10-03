-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers             = require "spec.helpers"
local cjson               = require "cjson"
local pl_path             = require "pl.path"
local pl_file             = require "pl.file"
local http_mock           = require "spec.helpers.http_mock"

local ee_helpers          = require "spec-ee.helpers"
local table_nkeys         = require "table.nkeys"

local CP_PREFIX           = "servroot_cp"
local DP_PREFIX           = "servroot_dp"
local TOKEN               = "01dd4c9e-cb5e-4b26-9e49-4eb0509fbd68"
local TOKEN_FILE          = ".request_debug_token"
local PLGUINS_ENABLED     = "bundled,enable-buffering-response,muti-external-http-calls,rate-limiting-advanced"
local TIME_TO_FIRST_BYTE  = 250  -- milliseconds
local STREAMING           = 400  -- seconds



local function setup_route(path, upstream)
  local admin_client = helpers.admin_client()

  local res = assert(admin_client:send {
    method = "POST",
    path = "/services",
    body = {
      url = upstream,
    },
    headers = {
      ["Content-Type"] = "application/json",
    },
  })

  local body = assert(cjson.decode(assert.res_status(201, res)))
  local service_id = assert(body.id)

  res = assert(admin_client:send {
    method = "POST",
    path = "/routes",
    body = {
      paths = { path },
      service = {
        id = service_id,
      },
    },
    headers = {
      ["Content-Type"] = "application/json",
    },
  })

  body = assert(cjson.decode(assert.res_status(201, res)))
  admin_client:close()

  return assert(body.id)
end


local function delete_route(route)
  local admin_client = helpers.admin_client()
  local res = assert(admin_client:send {
    method = "DELETE",
    path = "/routes/" .. route,
  })

  assert.res_status(204, res)
  admin_client:close()
end


local function setup_plugin(route_id, plugin_name, config)
  local admin_client = helpers.admin_client()
  local res = assert(admin_client:send {
    method = "POST",
    path = "/plugins",
    body = {
      name = plugin_name,
      config = config,
      route = {
        id = route_id,
      }
    },
    headers = {
      ["Content-Type"] = "application/json",
    },
  })

  local body = assert(cjson.decode(assert.res_status(201, res)))
  admin_client:close()

  return assert(body.id)
end


local function delete_plugin(plugin)
  local admin_client = helpers.admin_client()
  local res = assert(admin_client:send {
    method = "DELETE",
    path = "/plugins/" .. plugin,
  })

  assert.res_status(204, res)
  admin_client:close()
end


local function get_token_file_content(deployment)
  local path

  if deployment == "traditional" then
    path = pl_path.join(helpers.test_conf.prefix, TOKEN_FILE)

  else
    assert(deployment == "hybrid", "unknown deploy mode")
    path = pl_path.join(DP_PREFIX, TOKEN_FILE)
  end

  return pl_file.read(path)
end


local function assert_token_file_exists(deployment)
  return assert(get_token_file_content(deployment))
end


local function assert_cp_has_no_token_file(deployment)
  if deployment ~= "hybrid" then
    return
  end

  local path = pl_path.join(CP_PREFIX, TOKEN_FILE)
  assert(not pl_path.exists(path), "token file should not exist in CP")
end


local function get_output_header(_deployment, path, filter, fake_ip, token)
  local proxy_client = helpers.proxy_client()
  local res = assert(proxy_client:send {
    method = "GET",
    path = path,
    headers = {
      ["X-Kong-Request-Debug"] = filter or "*",
      ["X-Kong-Request-Debug-Token"] = token,
      ["X-Real-IP"] = fake_ip or "127.0.0.1",
    }
  })
  assert.not_same(500, res.status)
  res:read_body() -- discard body

  if not res.headers["X-Kong-Request-Debug-Output"] then
    return nil
  end

  local json = assert(cjson.decode(res.headers["X-Kong-Request-Debug-Output"]))
  assert.falsy(json.dangling)
  proxy_client:close()
  return json
end


local function get_output_log(deployment, path, filter, fake_ip, token)
  local proxy_client = helpers.proxy_client()
  local res = assert(proxy_client:send {
    method = "GET",
    path = path,
    headers = {
      ["X-Kong-Request-Debug"] = filter or "*",
      ["X-Kong-Request-Debug-Token"] = token,
      ["X-Kong-Request-Debug-Log"] = "true",
      ["X-Real-IP"] = fake_ip or "127.0.0.1",
    }
  })
  assert.not_same(500, res.status)
  res:read_body() -- discard body

  if not res.headers["X-Kong-Request-Debug-Output"] then
    return nil
  end

  local output = assert(cjson.decode(res.headers["X-Kong-Request-Debug-Output"]))
  local debug_id = assert(output.debug_id)

  local keyword = "[request-debug] id: " .. debug_id

  if deployment == "traditional" then
    path = pl_path.join(helpers.test_conf.prefix, "logs/error.log")

  else
    assert(deployment == "hybrid", "unknown deploy mode")
    path = pl_path.join(DP_PREFIX, "logs/error.log")
  end

  local json
  local truncated = false

  pcall(function()
    helpers.pwait_until(function()
      json = ""
      local content = assert(pl_file.read(path))
      local start_idx = assert(content:find(keyword, nil, true))
      start_idx = assert(content:find("output: ", start_idx, true))
      local end_idx

      while true do
        end_idx = assert(content:find(" while logging request", start_idx, true))
        json = json .. content:sub(start_idx + #"output: ", end_idx - 1)
        start_idx = content:find(keyword, end_idx, true)
        if not start_idx then
          break
        end

        truncated = true
        start_idx = assert(content:find("output: ", start_idx, true))
      end

      json = assert(cjson.decode(json))
    end, 10)
  end)

  if not json then
    return nil
  end

  assert.falsy(json.dangling)
  proxy_client:close()

  return json, truncated
end


local function assert_has_output_header(deployment, path, filter, fake_ip, token)
  return assert(get_output_header(deployment, path, filter, fake_ip, token), "output header should exist")
end


local function assert_has_output_log(deployment, path, filter, fake_ip, token)
  return assert(get_output_log(deployment, path, filter, fake_ip, token), "output log should exist")
end


local function assert_has_no_output_header(deployment, path, filter, fake_ip, token)
  assert(not get_output_header(deployment, path, filter, fake_ip, token), "output header should not exist")
end


local function assert_has_no_output_log(deployment, path, filter, fake_ip, token)
  assert(not get_output_log(deployment, path, filter, fake_ip, token), "output log should not exist")
end


local function assert_plugin_has_span(plugin_span, span_name)
  for _, span in pairs(plugin_span) do
    if span.child[span_name] then
      return true
    end
  end

  return true
end


local function start_kong(strategy, deployment, disable_req_dbg, token)
  local request_debug = nil
  if disable_req_dbg then
    request_debug = "off"
  end

  helpers.get_db_utils(strategy, nil, {
    "enable-buffering-response",
    "muti-external-http-calls",
  })

  if deployment == "traditional" then
    assert(helpers.start_kong({
      database   = strategy,
      nginx_conf = "spec/fixtures/custom_nginx.template",
      request_debug = request_debug,
      request_debug_token = token,
      trusted_ips = "0.0.0.0/0",
      plugins = PLGUINS_ENABLED,
      stream_listen = "127.0.0.1:" .. helpers.get_available_port(),
    }))

  else
    assert(deployment == "hybrid", "unknown deploy mode")

    assert(helpers.start_kong({
      role = "control_plane",
      cluster_cert = "spec/fixtures/kong_clustering.crt",
      cluster_cert_key = "spec/fixtures/kong_clustering.key",
      lua_ssl_trusted_certificate = "spec/fixtures/kong_clustering.crt",
      database = strategy,
      prefix = CP_PREFIX,
      db_update_frequency = 0.1,
      cluster_listen = "127.0.0.1:9005",
      nginx_conf = "spec/fixtures/custom_nginx.template",
      request_debug = request_debug,
      proxy_listen = "off",
      plugins = PLGUINS_ENABLED,
    }))

    assert(helpers.start_kong({
      role = "data_plane",
      database = "off",
      prefix = DP_PREFIX,
      cluster_cert = "spec/fixtures/kong_clustering.crt",
      cluster_cert_key = "spec/fixtures/kong_clustering.key",
      lua_ssl_trusted_certificate = "spec/fixtures/kong_clustering.crt",
      cluster_control_plane = "127.0.0.1:9005",
      request_debug = request_debug,
      request_debug_token = token,
      trusted_ips = "0.0.0.0/0",
      plugins = PLGUINS_ENABLED,
      stream_listen = "127.0.0.1:" .. helpers.get_available_port(),
    }))
  end
end


local function stop_kong(deployment)
  if deployment == "traditional" then
    assert(helpers.stop_kong())

  else
    assert(deployment == "hybrid", "unknown deploy mode")
    assert(helpers.stop_kong(CP_PREFIX))
    assert(helpers.stop_kong(DP_PREFIX))
  end
end


for _, strategy in helpers.each_strategy() do
for __, deployment in ipairs({"traditional", "hybrid"}) do

local desc = string.format("Request debug #%s #%s", strategy, deployment)

describe(desc, function()
  it("should enabled by default", function()
    finally(function()
      stop_kong(deployment)
    end)

    start_kong(strategy, deployment)
    assert_token_file_exists(deployment)
    assert_cp_has_no_token_file(deployment)
    assert_has_output_header(deployment, "/", "*")
  end)

  it("can be disabled manually", function()
    finally(function()
      stop_kong(deployment)
    end)

    start_kong(strategy, deployment, true)

    local has_token_file = pcall(assert_token_file_exists, deployment)
    assert(not has_token_file, "token file should not exist")

    assert_has_no_output_header(deployment, "/", "*")
  end)

  it("generating token randomly if not set", function()
    finally(function()
      stop_kong(deployment)
    end)

    start_kong(strategy, deployment)
    local token = assert_token_file_exists(deployment)

    assert_has_output_header(deployment, "/", "*", "1.1.1.1", token)
    assert_has_no_output_header(deployment, "/", "*", "1.1.1.1", "invalid-token")
  end)

  it("token can be set manually", function()
    finally(function()
      stop_kong(deployment)
    end)

    start_kong(strategy, deployment, nil, TOKEN)
    local token = assert_token_file_exists(deployment)
    assert.same(TOKEN, token)

    assert_has_output_header(deployment, "/", "*", "1.1.1.1", TOKEN)
    assert_has_no_output_header(deployment, "/", "*", "1.1.1.1", "invalid-token")
  end)
end)

describe(desc, function()
  local mock, upstream

  lazy_setup(function()
    start_kong(strategy, deployment, nil, TOKEN)
    assert_token_file_exists(deployment)
    assert_cp_has_no_token_file(deployment)

    mock = assert(http_mock.new(nil, {
      ["/"] = {
        content = string.format([[
          ngx.sleep(%s / 1000)
          ngx.print("Hello")
          ngx.flush(true)
  
          ngx.sleep(%s / 1000)
          ngx.print(" World!")
          ngx.flush(true)
        ]], TIME_TO_FIRST_BYTE, STREAMING),
      },
    }, nil))
    assert(mock:start())
    upstream = "http://localhost:" .. mock:get_default_port()
  end)

  lazy_teardown(function()
    stop_kong(deployment)
    assert(mock:stop())
  end)

  it("do nothing if no debug header", function()
    local proxy_client = helpers.proxy_client()
    local res = assert(proxy_client:send {
      method = "GET",
      path = "/",
    })
    assert.not_same(500, res.status)
    res:read_body() -- discard body
    assert.same(nil, res.headers["X-Kong-Request-Debug-Output"])
  end)

  it("clients from the loopback don't need a token", function()
    assert_has_output_header(deployment, "/", "*", nil, nil)
  end)

  it("clients from the non-loopback need a token", function()
    assert_has_no_output_header(deployment, "/", "*", "1.1.1.1", nil)
    assert_has_no_output_log(deployment, "/", "*", "1.1.1.1", nil)
    assert_has_output_header(deployment, "/", "*", "1.1.1.1", TOKEN)
  end)

  it("has debug_id and workspace_id", function()
    local route_id = setup_route("/dummy", upstream)

    finally(function()
      if route_id then
        delete_route(route_id)
      end
    end)

    helpers.wait_for_all_config_update()

    local header_output = assert_has_output_header(deployment, "/dummy", "*")
    local log_output = assert_has_output_log(deployment, "/dummy", "*")

    assert.truthy(header_output.debug_id)
    assert.truthy(header_output.workspace_id)

    assert.truthy(log_output.debug_id)
    assert.truthy(log_output.workspace_id)
  end)

  it("upstream span", function()
    local route_id = setup_route("/slow-streaming", upstream)

    finally(function()
      if route_id then
        delete_route(route_id)
      end
    end)

    helpers.wait_for_all_config_update()

    local header_output = assert_has_output_header(deployment, "/slow-streaming", "*")
    local log_output = assert_has_output_log(deployment, "/slow-streaming", "*")

    local total_header = assert(tonumber(header_output.child.upstream.total_time))
    local tfb_header = assert(tonumber(header_output.child.upstream.child.time_to_first_byte.total_time))
    assert.falsy(header_output.child.upstream.child.streaming)
    assert.same(total_header, tfb_header)

    local total_log = assert(tonumber(log_output.child.upstream.total_time))
    local tfb_log = assert(tonumber(log_output.child.upstream.child.time_to_first_byte.total_time))
    local streaming = assert(tonumber(log_output.child.upstream.child.streaming.total_time))
    assert.near(tfb_header, tfb_log, 10)
    assert.same(total_log, tfb_log + streaming)

    assert.near(TIME_TO_FIRST_BYTE, tfb_log, 50)
    assert.near(STREAMING, streaming, 50)
  end)

  it("rewrite, access, balancer, header_filter, body_filter, log, plugin span, dns span", function()
    local route_id = setup_route("/mutiple-spans", upstream)

    finally(function()
      if route_id then
        delete_route(route_id)
      end
    end)

    helpers.wait_for_all_config_update()

    local header_output = assert_has_output_header(deployment, "/mutiple-spans", "*")
    local log_output = assert_has_output_log(deployment, "/mutiple-spans", "*")

    assert.truthy(header_output.child.rewrite)
    assert.truthy(header_output.child.access)
    assert.truthy(header_output.child.access.child.dns) -- upstream is resolved in access phase
    assert(header_output.child.access.child.dns.child.localhost.child.resolve.cache_hit ~= nil, "dns cache hit should be recorded")
    assert.truthy(header_output.child.balancer)
    assert.truthy(header_output.child.header_filter)

    assert.truthy(log_output.child.rewrite)
    assert.truthy(log_output.child.access)
    assert.truthy(log_output.child.access.child.dns) -- upstream is resolved in access phase
    assert(log_output.child.access.child.dns.child.localhost.child.resolve.cache_hit ~= nil, "dns cache hit should be recorded")
    assert.truthy(log_output.child.balancer)
    assert.truthy(log_output.child.header_filter)
    assert.truthy(log_output.child.body_filter)
    assert.truthy(log_output.child.log)
  end)

  it("subrequests involved", function()
    local route_id = setup_route("/subrequests", upstream)
    -- buffering resposne will issue a subrequest
    local plugin_id = setup_plugin(route_id, "enable-buffering-response", {})

    finally(function()
      if plugin_id then
        delete_plugin(plugin_id)
      end

      if route_id then
        delete_route(route_id)
      end
    end)

    helpers.wait_for_all_config_update()

    local header_output = assert_has_output_header(deployment, "/subrequests", "*")
    local log_output = assert_has_output_log(deployment, "/subrequests", "*")

    -- spans of main request
    assert.truthy(header_output.child.rewrite)
    assert.truthy(header_output.child.access)
    assert.truthy(header_output.child.access.child.dns) -- upstream is resolved in access phase
    assert.truthy(header_output.child.response)

    assert.truthy(log_output.child.rewrite)
    assert.truthy(log_output.child.access)
    assert.truthy(log_output.child.access.child.dns) -- upstream is resolved in access phase
    assert.truthy(log_output.child.body_filter)
    assert.truthy(log_output.child.log)

    -- spans of subrequest
    assert.truthy(header_output.child.response.child.balancer)
    assert.truthy(header_output.child.response.child.header_filter)
    assert.truthy(header_output.child.response.child.plugins)
    assert.truthy(header_output.child.response.child.plugins.child["enable-buffering-response"])

    assert.truthy(log_output.child.response.child.balancer)
    assert.truthy(log_output.child.response.child.header_filter)
    assert.truthy(log_output.child.response.child.body_filter)
    assert.truthy(log_output.child.response.child.plugins)
    assert.truthy(log_output.child.response.child.plugins.child["enable-buffering-response"])
  end)

  it("external_http span", function()
    local route_id = setup_route("/external_http", upstream)
    local plugin_id = setup_plugin(route_id, "muti-external-http-calls", { calls = 1 })

    finally(function()
      if plugin_id then
        delete_plugin(plugin_id)
      end

      if route_id then
        delete_route(route_id)
      end
    end)

    helpers.wait_for_all_config_update()

    local header_output = assert_has_output_header(deployment, "/external_http", "*")
    local log_output = assert_has_output_log(deployment, "/external_http", "*")

    local plugin_span = assert.truthy(header_output.child.access.child.plugins.child["muti-external-http-calls"].child)
    assert_plugin_has_span(plugin_span, "external_http")

    plugin_span = assert.truthy(log_output.child.access.child.plugins.child["muti-external-http-calls"].child)
    assert_plugin_has_span(plugin_span, "external_http")
  end)

  it("redis span", function()
    local route_id = setup_route("/redis", upstream)
    local plugin_id = setup_plugin(route_id, "rate-limiting", {
      second            = 9999,
      policy            = "redis",
      redis_host        = helpers.redis_host,
      redis_port        = helpers.redis_port,
      fault_tolerant    = false,
      redis_timeout     = 10000,
    })

    finally(function()
      if plugin_id then
        delete_plugin(plugin_id)
      end

      if route_id then
        delete_route(route_id)
      end
    end)

    helpers.wait_for_all_config_update()

    local header_output = assert_has_output_header(deployment, "/redis", "*")
    local log_output = assert_has_output_log(deployment, "/redis", "*")

    local plugin_span = assert.truthy(header_output.child.access.child.plugins.child["rate-limiting"].child)
    assert_plugin_has_span(plugin_span, "redis")

    plugin_span = assert.truthy(log_output.child.access.child.plugins.child["rate-limiting"].child)
    assert_plugin_has_span(plugin_span, "redis")
  end)

  it("truncate/split too large debug output", function()
    local route_id = setup_route("/large_debug_output", upstream)
    local plugin_id = setup_plugin(route_id, "muti-external-http-calls", { calls = 50 })

    finally(function()
      if plugin_id then
        delete_plugin(plugin_id)
      end

      if route_id then
        delete_route(route_id)
      end
    end)

    helpers.wait_for_all_config_update()

    local header_output = assert_has_output_header(deployment, "/large_debug_output", "*", "1.1.1.1", TOKEN)
    local _, truncated = assert_has_output_log(deployment, "/large_debug_output", "*", "1.1.1.1", TOKEN)

    assert.truthy(header_output.truncated)
    assert.truthy(truncated)
  end)

  it("invalid X-Kong-Request-Debug request header should not trigger this feature", function()
    local route_id = setup_route("/invalid_header", upstream)

    finally(function()
      if route_id then
        delete_route(route_id)
      end
    end)

    helpers.wait_for_all_config_update()

    assert_has_no_output_header(deployment, "/invalid_header", "invalid")
    assert_has_no_output_log(deployment, "/invalid_header", "invalid")
  end)

  -- XXX EE [[
  it("phase filter", function()
    local route_id = setup_route("/mutiple-spans", upstream)

    finally(function()
      if route_id then
        delete_route(route_id)
      end
    end)

    helpers.wait_for_all_config_update()

    local phases = {
      rewrite = {
        in_header = true,
        in_log = true,
      },
      access = {
        in_header = true,
        in_log = true,
      },
      balancer = {
        in_header = true,
        in_log = true,
      },
      header_filter = {
        in_header = true,
        in_log = true,
      },
      body_filter = {
        in_header = false,
        in_log = true,
      },
      upstream = {
        in_header = true,
        in_log = true,
      },
    }

    for phase_name, cond in pairs(phases) do
      local header_output = assert_has_output_header(deployment, "/mutiple-spans", phase_name)
      local log_output = assert_has_output_log(deployment, "/mutiple-spans", phase_name)

      if cond.in_header then
        assert.same(1, table_nkeys(header_output.child))
        assert.truthy(header_output.child[phase_name])
      end

      if cond.in_log then
        assert.same(1, table_nkeys(log_output.child))
        assert.truthy(log_output.child[phase_name])
      end
    end

    local header_output = assert_has_output_header(deployment, "/mutiple-spans", "rewrite, header_filter,body_filter,upstream")
    local log_output = assert_has_output_log(deployment, "/mutiple-spans", "rewrite,header_filter,body_filter, upstream")

    assert.same(4 - 1, table_nkeys(header_output.child)) -- header_output should not has body_filter
    assert.truthy(header_output.child.rewrite)
    assert.truthy(header_output.child.header_filter)
    assert.truthy(header_output.child.upstream)

    assert.same(4, table_nkeys(log_output.child))
    assert.truthy(log_output.child.rewrite)
    assert.truthy(log_output.child.header_filter)
    assert.truthy(log_output.child.body_filter)
    assert.truthy(log_output.child.upstream)
  end)
  -- XXX EE ]]

  -- XXX EE [[
  it("invaliadte phase filter should not trigger this feature", function()
    local route_id = setup_route("/mutiple-spans", upstream)

    finally(function()
      if route_id then
        delete_route(route_id)
      end
    end)

    helpers.wait_for_all_config_update()

    local invaliadte_filters = {
      "invalid_phase",
      "invalid-phase",
      "invalid_phase,rewrite",
      "invalid-phase,rewrite",
      "rewrite,invalid_phase",
      "rewrite,invalid-phase",
      "rewrite,invalid_phase,access",
      "rewrite,invalid-phase,access",
    }

    for _, filter in ipairs(invaliadte_filters) do
      assert_has_no_output_header(deployment, "/mutiple-spans", filter)
      assert_has_no_output_log(deployment, "/mutiple-spans", filter)
    end
  end)
  -- XXX EE ]]

  -- XXX EE [[
  it("rediscluster span", function()
    local route_id = setup_route("/rediscluster_span", upstream)
    local plugin_id = setup_plugin(route_id, "rate-limiting-advanced", {
      window_size = { 1 },
      limit = { 99999 },
      sync_rate = 0, -- sync to redis for each request
      strategy = "redis",
      redis = {
        cluster_addresses = ee_helpers.parsed_redis_cluster_addresses(),
      },
    })

    finally(function()
      if plugin_id then
        delete_plugin(plugin_id)
      end

      if route_id then
        delete_route(route_id)
      end
    end)

    helpers.wait_for_all_config_update()

    local header_output = assert_has_output_header(deployment, "/rediscluster_span", "*")
    local log_output = assert_has_output_log(deployment, "/rediscluster_span", "*")

    local plugin_span = assert.truthy(header_output.child.access.child.plugins.child["rate-limiting-advanced"].child)
    assert_plugin_has_span(plugin_span, "redis")

    plugin_span = assert.truthy(log_output.child.access.child.plugins.child["rate-limiting-advanced"].child)
    assert_plugin_has_span(plugin_span, "redis")
  end)
  -- XXX EE ]]

end) -- describe
end  -- for deployment
end  -- for strategy