#!/usr/bin/env tarantool
local http_router = require('http.router')
local http_server = require('http.server')
local tsgi = require('http.tsgi')
local json = require('json')

box.cfg{}  -- luacheck: ignore

local httpd = http_server.new('127.0.0.1', 12345, {
    log_requests = true,
    log_errors = true
})

-- TODO
--[[
local function preroute_middleware_1(env)

end
--]]

-- TODO: maybe route-metadata is passed here also?
--
-- Of course, only generic one can be applied,
-- since middleware shouldn't be tied to any
-- specific router.
--
local function middleware_1(env)
    env['session_id'] = 'abacaba'
    local handler = tsgi.next_handler(env)
    return handler(env)
end

local function middleware_2(env)
    if env['session_id'] == 'abacaba' then
        env['authenticated'] = true
    end
    local handler = tsgi.next_handler(env)
    local resp = handler(env)
    return resp
end

local function userdefined_handler(request)
    local authenticated = request.env['authenticated']
    if authenticated then
        return {
            status = 200, body = json.encode({authenticated = 'yes'})
        }
    end
    return {
        status = 200, body = json.encode({authenticated = 'no'})
    }
end

local router = http_router.new(httpd) -- luacheck: ignore
    :route({
            method = 'GET',
            path = '/fruits/apple',
            middleware = {
                middleware_1,
                middleware_2,
            }
        },
        userdefined_handler
    )

httpd:start()
