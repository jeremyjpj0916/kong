return [[
> if anonymous_reports then
${{SYSLOG_REPORTS}}
> end

log_format basic '$remote_addr [$time_local] '
                 '$protocol $status $bytes_sent $bytes_received '
                 '$session_time';

lua_package_path '${{LUA_PACKAGE_PATH}};;';
lua_package_cpath '${{LUA_PACKAGE_CPATH}};;';

lua_shared_dict stream_kong                5m;

lua_shared_dict stream_kong_core_db_cache  ${{MEM_CACHE_SIZE}};
lua_shared_dict stream_kong_db_cache       ${{MEM_CACHE_SIZE}};

lua_shared_dict stream_kong_core_db_cache_miss   12m;
lua_shared_dict stream_kong_db_cache_miss   12m;

> if database == "off" then
lua_shared_dict stream_kong_core_db_cache_2     ${{MEM_CACHE_SIZE}};
lua_shared_dict stream_kong_db_cache_2     ${{MEM_CACHE_SIZE}};
> end

> if database == "off" then
lua_shared_dict stream_kong_core_db_cache_miss_2     ${{MEM_CACHE_SIZE}};
lua_shared_dict stream_kong_db_cache_miss_2 12m;
> end

lua_shared_dict stream_kong_locks          8m;
lua_shared_dict stream_kong_process_events 5m;
lua_shared_dict stream_kong_cluster_events 5m;
lua_shared_dict stream_kong_healthchecks   5m;
lua_shared_dict stream_kong_rate_limiting_counters 12m;
> if database == "cassandra" then
lua_shared_dict stream_kong_cassandra      5m;
> end
lua_shared_dict stream_prometheus_metrics  5m;

# injected nginx_stream_* directives
> for _, el in ipairs(nginx_stream_directives) do
$(el.name) $(el.value);
> end

init_by_lua_block {
    -- shared dictionaries conflict between stream/http modules. use a prefix.
    local shared = ngx.shared
    ngx.shared = setmetatable({}, {
        __index = function(t, k)
            return shared["stream_"..k]
        end,
    })

    Kong = require 'kong'
    Kong.init()
}

init_worker_by_lua_block {
    Kong.init_worker()
}

upstream kong_upstream {
    server 0.0.0.1:1;
    balancer_by_lua_block {
        Kong.balancer()
    }
}

> if #stream_listeners > 0 then
server {
> for _, entry in ipairs(stream_listeners) do
    listen $(entry.listener);
> end

    access_log ${{PROXY_ACCESS_LOG}} basic;
    error_log ${{PROXY_ERROR_LOG}} ${{LOG_LEVEL}};

> for i = 1, #trusted_ips do
    set_real_ip_from   $(trusted_ips[i]);
> end

    # injected nginx_sproxy_* directives
> for _, el in ipairs(nginx_sproxy_directives) do
    $(el.name) $(el.value);
> end

> if stream_proxy_ssl_enabled then
    ssl_certificate ${{SSL_CERT}};
    ssl_certificate_key ${{SSL_CERT_KEY}};
> if ssl_ciphers then
    ssl_ciphers ${{SSL_CIPHERS}};
> end
    ssl_certificate_by_lua_block {
        Kong.ssl_certificate()
    }
> end

    preread_by_lua_block {
        Kong.preread()
    }

    proxy_pass kong_upstream;
    proxy_ssl on;

    log_by_lua_block {
        Kong.log()
    }
}
> end -- #stream_listeners > 0
]]
