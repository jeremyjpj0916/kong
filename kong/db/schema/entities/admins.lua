-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local typedefs = require "kong.db.schema.typedefs"
local ee_typedefs = require "kong.enterprise_edition.db.typedefs"

return {
  name         = "admins",
  primary_key  = { "id" },
  endpoint_key = "username",
  dao          = "kong.db.dao.admins",
  db_export    = false,
  
  fields = {
    { id             = typedefs.uuid },
    { created_at     = typedefs.auto_timestamp_s },
    { updated_at     = typedefs.auto_timestamp_s },
    { username       = { description = "The admin's username.", type = "string", unique = true, required = true }, },
    { username_lower = { description = "The admin's username in lowercase.", type = "string" }, },
    { custom_id      = { description = "The Admin’s custom ID.", type = "string", unique = true }, },
    { email          = ee_typedefs.email { unique = true } },
    { status         = ee_typedefs.admin_status { required = true } },
    { rbac_token_enabled = { description = "Allows the Admin to use and reset their RBAC token; true by default.", type = "boolean", required = true, default = true } },
    { consumer       = { description = "The consumer.", type = "foreign", reference = "consumers", required = true } },
    { rbac_user      = { description = "The rbac user Id.", type = "foreign", reference = "rbac_users", required = true } },
  },
}