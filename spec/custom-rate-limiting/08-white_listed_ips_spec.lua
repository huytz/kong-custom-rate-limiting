local helpers = require "spec.helpers"
local cjson = require "cjson"


local UPSTREAM_URL = helpers.mock_upstream_url


local function GET(url, opt)
  local client = helpers.proxy_client()
  local res, err = client:get(url, opt)
  if not res then
    client:close()
    return nil, err
  end

  assert(res:read_body())
  client:close()

  return res
end


local function setup_service(admin_client, url)
  local service = assert(admin_client:send({
    method = "POST",
    path = "/services",
    body = {
      url = url,
    },
    headers = {
      ["Content-Type"] = "application/json",
    },
  }))

  return cjson.decode(assert.res_status(201, service))
end


local function setup_route(admin_client, service, paths)
  local route = assert(admin_client:send({
    method = "POST",
    path = "/routes",
    body = {
      service = { id = service.id },
      paths = paths,
    },
    headers = {
      ["Content-Type"] = "application/json",
    },
  }))

  return cjson.decode(assert.res_status(201, route))
end


local function setup_rl_plugin(admin_client, conf, service)
  local plugin = assert(admin_client:send({
    method = "POST",
    path = "/plugins",
    body = {
      name = "rate-limiting",
      service = { id = service.id },
      config = conf,
    },
    headers = {
      ["Content-Type"] = "application/json",
    },
  }))

  return cjson.decode(assert.res_status(201, plugin))
end


local function delete_service(admin_client, service)
  local res = assert(admin_client:send({
    method = "DELETE",
    path = "/services/" .. service.id,
  }))

  assert.res_status(204, res)
end


local function delete_route(admin_client, route)
  local res = assert(admin_client:send({
    method = "DELETE",
    path = "/routes/" .. route.id,
  }))

  assert.res_status(204, res)
end


local function delete_plugin(admin_client, plugin)
  local res = assert(admin_client:send({
    method = "DELETE",
    path = "/plugins/" .. plugin.id,
  }))

  assert.res_status(204, res)
end


for _, strategy in helpers.each_strategy() do
  describe("Plugin: rate-limiting (white_listed_ips) [#" .. strategy .. "]", function()
    local admin_client
    local bp

    lazy_setup(function()
      bp = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "plugins",
      })

      assert(helpers.start_kong({
        database   = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        plugins = "bundled,rate-limiting",
        trusted_ips = "0.0.0.0/0,::/0",  -- Trust all IPs to allow X-Real-IP header
      }))

      admin_client = helpers.admin_client()
    end)

    lazy_teardown(function()
      if admin_client then
        admin_client:close()
      end

      helpers.stop_kong()
    end)

    describe("whitelist functionality", function()
      it("allows requests from whitelisted IP to bypass rate limiting", function()
        local test_path = "/test"
        local whitelisted_ip = "127.0.0.100"

        local service = setup_service(admin_client, UPSTREAM_URL)
        local route = setup_route(admin_client, service, { test_path })
        local rl_plugin = setup_rl_plugin(admin_client, {
          second = 1,  -- Very low limit to test easily
          white_listed_ips = { whitelisted_ip }
        }, service)

        finally(function()
          delete_plugin(admin_client, rl_plugin)
          delete_route(admin_client, route)
          delete_service(admin_client, service)
        end)

        helpers.wait_for_all_config_update({
          override_global_rate_limiting_plugin = true,
        })

        -- Make multiple requests from whitelisted IP - should all succeed
        for i = 1, 5 do
          local res = GET(test_path, {
            headers = { ["X-Real-IP"] = whitelisted_ip }
          })
          assert.res_status(200, res)
          -- Should not have rate limit headers when whitelisted
          assert.is_nil(res.headers["RateLimit-Limit"])
          assert.is_nil(res.headers["RateLimit-Remaining"])
        end
      end)

      it("rate limits requests from non-whitelisted IP", function()
        local test_path = "/test"
        local whitelisted_ip = "127.0.0.100"
        local non_whitelisted_ip = "127.0.0.200"

        local service = setup_service(admin_client, UPSTREAM_URL)
        local route = setup_route(admin_client, service, { test_path })
        local rl_plugin = setup_rl_plugin(admin_client, {
          second = 1,  -- Very low limit to test easily
          white_listed_ips = { whitelisted_ip }
        }, service)

        finally(function()
          delete_plugin(admin_client, rl_plugin)
          delete_route(admin_client, route)
          delete_service(admin_client, service)
        end)

        helpers.wait_for_all_config_update({
          override_global_rate_limiting_plugin = true,
        })

        -- First request from non-whitelisted IP should succeed
        local res1 = GET(test_path, {
          headers = { ["X-Real-IP"] = non_whitelisted_ip }
        })
        assert.res_status(200, res1)
        assert.not_nil(res1.headers["RateLimit-Limit"])
        assert.not_nil(res1.headers["RateLimit-Remaining"])

        helpers.wait_timer("rate-limiting", true, "any-finish")

        -- Second request should be rate limited
        local res2 = GET(test_path, {
          headers = { ["X-Real-IP"] = non_whitelisted_ip }
        })
        local body2 = assert.res_status(429, res2)
        local json2 = cjson.decode(body2)
        assert.matches("API rate limit exceeded", json2.message)
      end)

      it("allows requests from IP in CIDR range", function()
        local test_path = "/test"
        local cidr_range = "192.168.1.0/24"
        local ip_in_range = "192.168.1.50"

        local service = setup_service(admin_client, UPSTREAM_URL)
        local route = setup_route(admin_client, service, { test_path })
        local rl_plugin = setup_rl_plugin(admin_client, {
          second = 1,
          white_listed_ips = { cidr_range }
        }, service)

        finally(function()
          delete_plugin(admin_client, rl_plugin)
          delete_route(admin_client, route)
          delete_service(admin_client, service)
        end)

        helpers.wait_for_all_config_update({
          override_global_rate_limiting_plugin = true,
        })

        -- Make multiple requests from IP in CIDR range - should all succeed
        for i = 1, 5 do
          local res = GET(test_path, {
            headers = { ["X-Real-IP"] = ip_in_range }
          })
          assert.res_status(200, res)
          assert.is_nil(res.headers["RateLimit-Limit"])
        end
      end)

      it("rate limits requests from IP outside CIDR range", function()
        local test_path = "/test"
        local cidr_range = "192.168.1.0/24"
        local ip_outside_range = "192.168.2.50"

        local service = setup_service(admin_client, UPSTREAM_URL)
        local route = setup_route(admin_client, service, { test_path })
        local rl_plugin = setup_rl_plugin(admin_client, {
          second = 1,
          white_listed_ips = { cidr_range }
        }, service)

        finally(function()
          delete_plugin(admin_client, rl_plugin)
          delete_route(admin_client, route)
          delete_service(admin_client, service)
        end)

        helpers.wait_for_all_config_update({
          override_global_rate_limiting_plugin = true,
        })

        -- First request should succeed
        local res1 = GET(test_path, {
          headers = { ["X-Real-IP"] = ip_outside_range }
        })
        assert.res_status(200, res1)

        helpers.wait_timer("rate-limiting", true, "any-finish")

        -- Second request should be rate limited
        local res2 = GET(test_path, {
          headers = { ["X-Real-IP"] = ip_outside_range }
        })
        assert.res_status(429, res2)
      end)

      it("works with multiple whitelisted IPs", function()
        local test_path = "/test"
        local ip1 = "127.0.0.100"
        local ip2 = "127.0.0.101"
        local ip3 = "127.0.0.102"

        local service = setup_service(admin_client, UPSTREAM_URL)
        local route = setup_route(admin_client, service, { test_path })
        local rl_plugin = setup_rl_plugin(admin_client, {
          second = 1,
          white_listed_ips = { ip1, ip2, ip3 }
        }, service)

        finally(function()
          delete_plugin(admin_client, rl_plugin)
          delete_route(admin_client, route)
          delete_service(admin_client, service)
        end)

        helpers.wait_for_all_config_update({
          override_global_rate_limiting_plugin = true,
        })

        -- All whitelisted IPs should bypass rate limiting
        for _, ip in ipairs({ ip1, ip2, ip3 }) do
          for i = 1, 3 do
            local res = GET(test_path, {
              headers = { ["X-Real-IP"] = ip }
            })
            assert.res_status(200, res)
            assert.is_nil(res.headers["RateLimit-Limit"])
          end
        end
      end)

      it("works without X-Real-IP header (uses direct connection IP)", function()
        local test_path = "/test"
        -- When no X-Real-IP header, Kong uses the direct connection IP
        -- In tests, this is typically 127.0.0.1

        local service = setup_service(admin_client, UPSTREAM_URL)
        local route = setup_route(admin_client, service, { test_path })
        local rl_plugin = setup_rl_plugin(admin_client, {
          second = 1,
          white_listed_ips = { "127.0.0.1" }
        }, service)

        finally(function()
          delete_plugin(admin_client, rl_plugin)
          delete_route(admin_client, route)
          delete_service(admin_client, service)
        end)

        helpers.wait_for_all_config_update({
          override_global_rate_limiting_plugin = true,
        })

        -- Make multiple requests without X-Real-IP header
        -- Should use direct connection IP (127.0.0.1) which is whitelisted
        for i = 1, 5 do
          local res = GET(test_path)
          assert.res_status(200, res)
          assert.is_nil(res.headers["RateLimit-Limit"])
        end
      end)

      it("works with empty whitelist (no bypass)", function()
        local test_path = "/test"

        local service = setup_service(admin_client, UPSTREAM_URL)
        local route = setup_route(admin_client, service, { test_path })
        local rl_plugin = setup_rl_plugin(admin_client, {
          second = 1,
          white_listed_ips = {}
        }, service)

        finally(function()
          delete_plugin(admin_client, rl_plugin)
          delete_route(admin_client, route)
          delete_service(admin_client, service)
        end)

        helpers.wait_for_all_config_update({
          override_global_rate_limiting_plugin = true,
        })

        -- First request should succeed
        local res1 = GET(test_path)
        assert.res_status(200, res1)
        assert.not_nil(res1.headers["RateLimit-Limit"])

        helpers.wait_timer("rate-limiting", true, "any-finish")

        -- Second request should be rate limited
        local res2 = GET(test_path)
        assert.res_status(429, res2)
      end)

      it("works without white_listed_ips config (normal rate limiting)", function()
        local test_path = "/test"

        local service = setup_service(admin_client, UPSTREAM_URL)
        local route = setup_route(admin_client, service, { test_path })
        local rl_plugin = setup_rl_plugin(admin_client, {
          second = 1
          -- No white_listed_ips configured
        }, service)

        finally(function()
          delete_plugin(admin_client, rl_plugin)
          delete_route(admin_client, route)
          delete_service(admin_client, service)
        end)

        helpers.wait_for_all_config_update({
          override_global_rate_limiting_plugin = true,
        })

        -- First request should succeed
        local res1 = GET(test_path)
        assert.res_status(200, res1)
        assert.not_nil(res1.headers["RateLimit-Limit"])

        helpers.wait_timer("rate-limiting", true, "any-finish")

        -- Second request should be rate limited
        local res2 = GET(test_path)
        assert.res_status(429, res2)
      end)
    end)
  end)
end

