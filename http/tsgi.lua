local log = require('log')

local KEY_HTTPD = 'tarantool.http.httpd'
local KEY_SOCK = 'tarantool.http.sock'
local KEY_REMAINING = 'tarantool.http.sock_remaining_len'
local KEY_PARSED_REQUEST = 'tarantool.http.parsed_request'
local KEY_PEER = 'tarantool.http.peer'

-- helpers

-- XXX: do it with lua-iterators
local function headers(env)
    local map = {}
    for name, value in pairs(env) do
        if string.startswith(name, 'HEADER_') then  -- luacheck: ignore
            map[name] = value
        end
    end
    return map
end

---

local function noop() end

local function tsgi_errors_write(self, msg)  -- luacheck: ignore
    log.error(msg)
end

local function tsgi_hijack(env)
    local httpd = env[KEY_HTTPD]
    local sock = env[KEY_SOCK]

    httpd.is_hijacked = true
    return sock
end

-- TODO: understand this. Maybe rewrite it to only follow
-- TSGI logic, and not router logic.
--
-- if opts is number, it specifies number of bytes to be read
-- if opts is a table, it specifies options
local function tsgi_input_read(self, opts, timeout)
    checks('table', '?number|string|table', '?number') -- luacheck: ignore
    local env = self._env

    local remaining = env[KEY_REMAINING]
    if not remaining then
        remaining = tonumber(env['HEADER_CONTENT-LENGTH'])  -- TODO: hyphen
        if not remaining then
            return ''
        end
    end

    if opts == nil then
        opts = remaining
    elseif type(opts) == 'number' then
        if opts > remaining then
            opts = remaining
        end
    elseif type(opts) == 'string' then
        opts = { size = remaining, delimiter = opts }
    elseif type(opts) == 'table' then
        local size = opts.size or opts.chunk
        if size and size > remaining then
            opts.size = remaining
            opts.chunk = nil
        end
    end

    local buf = env[KEY_SOCK]:read(opts, timeout)
    if buf == nil then
        env[KEY_REMAINING] = 0
        return ''
    end
    remaining = remaining - #buf
    assert(remaining >= 0)
    env[KEY_REMAINING] = remaining
    return buf
end

local function convert_headername(name)
    return 'HEADER_' .. string.upper(name)  -- TODO: hyphens
end

local function make_env(opts)
    local p = opts.parsed_request

    local env = {
        [KEY_SOCK] = opts.sock,
        [KEY_HTTPD] = opts.httpd,
        [KEY_PARSED_REQUEST] = p,          -- TODO: delete?
        [KEY_PEER] = opts.peer,            -- TODO: delete?

        ['tsgi.version'] = '1',
        ['tsgi.url_scheme'] = 'http',      -- no support for https yet
        ['tsgi.input'] = {
            read = tsgi_input_read,
            rewind = nil,                  -- non-rewindable by default
        },
        ['tsgi.errors'] = {
            write = tsgi_errors_write,
            flush = noop,                  -- TODO: implement
        },
        ['tsgi.hijack'] = setmetatable({}, {
            __call = tsgi_hijack,
        }),

        ['REQUEST_METHOD'] = p.method,
        ['PATH_INFO'] = p.path,
        ['QUERY_STRING'] = p.query,
        ['SERVER_NAME'] = opts.httpd.host,
        ['SERVER_PORT'] = opts.httpd.port,
        ['SERVER_PROTOCOL'] = string.format('HTTP/%d.%d', p.proto[1], p.proto[2]),
    }

    -- Pass through `env` to env['tsgi.*']:*() functions
    env['tsgi.input']._env = env
    env['tsgi.errors']._env = env
    env['tsgi.hijack']._env = env

    -- set headers
    for name, value in pairs(p.headers) do
        env[convert_headername(name)] = value
    end

    -- SCRIPT_NAME is a virtual location of your app.
    --
    -- Imagine you want to serve your HTTP API under prefix /test
    -- and later move it to /.
    --
    -- Instead of rewriting endpoints to your application, you do:
    --
    -- location /test/ {
    --     proxy_pass http://127.0.0.1:8001/test/;
    --     proxy_redirect http://127.0.0.1:8001/test/ http://$host/test/;
    --     proxy_set_header SCRIPT_NAME /test;
    -- }
    --
    -- Application source code is not touched.
    env['SCRIPT_NAME'] = env['HTTP_SCRIPT_NAME'] or ''
    env['HTTP_SCRIPT_NAME'] = nil

    return env
end

return {
    KEY_HTTPD = KEY_HTTPD,
    KEY_PARSED_REQUEST = KEY_PARSED_REQUEST,
    KEY_PEER = KEY_PEER,

    make_env = make_env,
    headers = headers,
}
