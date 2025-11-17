local plugin_name = "custom-rate-limiting"
local package_name = "kong-plugin-" .. plugin_name
local package_version = "0.1.0"
local rockspec_revision = "1"

local github_account_name = "Kong"
local github_repo_name = "kong-plugin"
local git_checkout = package_version == "dev" and "master" or package_version


package = package_name
version = package_version .. "-" .. rockspec_revision
supported_platforms = { "linux", "macosx" }
source = {
  url = "git+https://github.com/"..github_account_name.."/"..github_repo_name..".git",
  branch = git_checkout,
}


description = {
  summary = "Custom rate limiting plugin for Kong Gateway",
  homepage = "https://"..github_account_name..".github.io/"..github_repo_name,
  license = "Apache 2.0",
}


dependencies = {
}


build = {
  type = "builtin",
  modules = {
    ["kong.plugins."..plugin_name..".handler"] = "kong/plugins/"..plugin_name.."/handler.lua",
    ["kong.plugins."..plugin_name..".schema"] = "kong/plugins/"..plugin_name.."/schema.lua",
    ["kong.plugins."..plugin_name..".daos"] = "kong/plugins/"..plugin_name.."/daos.lua",
    ["kong.plugins."..plugin_name..".expiration"] = "kong/plugins/"..plugin_name.."/expiration.lua",
    ["kong.plugins."..plugin_name..".policies"] = "kong/plugins/"..plugin_name.."/policies/init.lua",
    ["kong.plugins."..plugin_name..".policies.cluster"] = "kong/plugins/"..plugin_name.."/policies/cluster.lua",
    ["kong.plugins."..plugin_name..".clustering.compat.redis_translation"] = "kong/plugins/"..plugin_name.."/clustering/compat/redis_translation.lua",
  }
}
