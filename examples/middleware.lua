#!/usr/bin/env tarantool
local http_router = require('http.router')
local http_server = require('http.server')
local tsgi = require('http.tsgi')
local json = require('json')
local log = require('log')

box.cfg{}  -- luacheck: ignore

local httpd = http_server.new('127.0.0.1', 12345, {
    log_requests = true,
    log_errors = true
})

local function swap_orange_and_apple(env)
    local path_info = env['PATH_INFO']
    log.info('swap_orange_and_apple: path_info = %s', path_info)
    if path_info == '/fruits/orange' then
        env['PATH_INFO'] = '/fruits/apple'
    elseif path_info == '/fruits/apple' then
        env['PATH_INFO'] = '/fruits/orange'
    end

    local handler = tsgi.next_handler(env)
    return handler(env)
end

local function add_helloworld_to_response(env)
    local handler = tsgi.next_handler(env)
    local resp = handler(env)

    local lua_body = json.decode(resp.body)
    lua_body.message = 'hello world!'
    resp.body = json.encode(lua_body)

    return resp
end

local function apple_handler(_)
    return {status = 200, body = json.encode({kind = 'apple'})}
end

local function orange_handler(_)
    return {status = 200, body = json.encode({kind = 'orange'})}
end

local _ = http_router.new(httpd, {
        preroute_middleware = {
            swap_orange_and_apple,
        }
    }) -- luacheck: ignore
    :route({
            method = 'GET',
            path = '/fruits/apple',
            middleware = {
                add_helloworld_to_response,
            }
        },
        apple_handler
    )
    :route({
            method = 'GET',
            path = '/fruits/orange',
            middleware = {
                add_helloworld_to_response,
            }
        },
        orange_handler
    )

httpd:start()
