local fs = require('http.router.fs')
local middleware = require('http.router.middleware')
local matching = require('http.router.matching')
local request_metatable = require('http.router.request').metatable

local utils = require('http.utils')
local tsgi = require('http.tsgi')

local function uri_file_extension(s, default)
    -- cut from last dot till the end
    local ext = string.match(s, '[.]([^.]+)$')
    if ext ~= nil then
        return ext
    end
    return default
end

-- TODO: move to router.request?
local function url_for_helper(tx, name, args, query)
    return tx:url_for(name, args, query)
end

local function request_from_env(env, router)  -- luacheck: ignore
    -- TODO: khm... what if we have nginx tsgi?
    -- we need to restrict ourselves to generic TSGI
    -- methods and properties!

    local request = {
        router = router,
        env = env,
        peer = env[tsgi.KEY_PEER],
        method = env['REQUEST_METHOD'],
        path = env['PATH_INFO'],
        query = env['QUERY_STRING'],
    }

    -- parse SERVER_PROTOCOL which is 'HTTP/<maj>.<min>'
    local maj = env['SERVER_PROTOCOL']:sub(-3, -3)
    local min = env['SERVER_PROTOCOL']:sub(-1, -1)
    request.proto = {
        [1] = tonumber(maj),
        [2] = tonumber(min),
    }

    request.headers = {}
    for name, value in pairs(tsgi.headers(env)) do
        -- strip HEADER_ part and convert to lowercase
        local converted_name = name:sub(8):lower()
        request.headers[converted_name] = value
    end

    return setmetatable(request, request_metatable)
end

local function main_endpoint_middleware(env)
    local self = env[tsgi.KEY_ROUTER]
    local format = uri_file_extension(env['PATH_INFO'], 'html')
    local r = env[tsgi.KEY_ROUTE]
    local request = request_from_env(env, self)
    if r == nil then
        return fs.static_file(self, request, format)
    end
    local stash = utils.extend(r.stash, { format = format })
    request.endpoint = r.endpoint  -- THIS IS ROUTE, BUT IS NAMED `ENDPOINT`! OH-MY-GOD!
    request.tstash   = stash
    return r.endpoint.sub(request)
end

local function dispatch_middleware(env)
    local self = env[tsgi.KEY_ROUTER]

    local r = self:match(env['REQUEST_METHOD'], env['PATH_INFO'])
    env[tsgi.KEY_ROUTE] = r

    -- TODO: filtering on m.path, m.method, etc.

    -- add route-specific middleware
    for _, m in pairs(self.middleware:ordered()) do
        tsgi.push_back_handler(env, m.sub)
    end

    -- finally, add user specified handler
    tsgi.push_back_handler(env, main_endpoint_middleware)

    return tsgi.invoke_next_handler(env)
end

local function handler(self, env)
    env[tsgi.KEY_ROUTER] = self

    -- set-up middleware chain
    tsgi.init_handlers(env)

    -- TODO: add pre-route middleware

    -- add routing
    tsgi.push_back_handler(env, dispatch_middleware)

    -- execute middleware chain from first
    return tsgi.invoke_next_handler(env)
end

-- TODO: `route` is not route, but path...
local function match_route(self, method, route)
    local filter = matching.transform_filter({
        method = method,
        path = route
    })

    local best_match = nil
    for _, r in pairs(self.routes) do
        local ok, match = matching.matches(r, filter)
        if ok and matching.better_than(match, best_match) then
            best_match = match
        end
    end

    if best_match == nil or best_match.route == nil then
        return nil
    end

    local resstash = {}
    for i = 1, #best_match.route.stash do
        resstash[best_match.route.stash[i]] = best_match.stash[i]
    end
    return {endpoint = best_match.route, stash = resstash}
end

local function set_helper(self, name, sub)
    if sub == nil or type(sub) == 'function' then
        self.helpers[ name ] = sub
        return self
    end
    utils.errorf("Wrong type for helper function: %s", type(sub))
end

local function set_hook(self, name, sub)
    if sub == nil or type(sub) == 'function' then
        self.hooks[ name ] = sub
        return self
    end
    utils.errorf("Wrong type for hook function: %s", type(sub))
end

local function url_for_route(r, args, query)
    if args == nil then
        args = {}
    end
    local name = r.path
    for i, sn in pairs(r.stash) do
        local sv = args[sn]
        if sv == nil then
            sv = ''
        end
        name = string.gsub(name, '[*:]' .. sn, sv, 1)
    end

    if query ~= nil then
        if type(query) == 'table' then
            local sep = '?'
            for k, v in pairs(query) do
                name = name .. sep .. utils.uri_escape(k) .. '=' .. utils.uri_escape(v)
                sep = '&'
            end
        else
            name = name .. '?' .. query
        end
    end

    if string.match(name, '^/') == nil then
        return '/' .. name
    else
        return name
    end
end

local possible_methods = {
    GET    = 'GET',
    HEAD   = 'HEAD',
    POST   = 'POST',
    PUT    = 'PUT',
    DELETE = 'DELETE',
    PATCH  = 'PATCH',
}

-- TODO: error-handling, validation
local function use_middleware(self, opts, sub)
    if type(opts) ~= 'table' or type(self) ~= 'table' then
        error("Usage: router:route({ ... }, function(cx) ... end)")
    end
    assert(type(opts.name) == 'string')

    local opts = table.deepcopy(opts)   -- luacheck: ignore
    opts.sub = sub

    return self.middleware:use(opts)
end

local function add_route(self, opts, sub)
    if type(opts) ~= 'table' or type(self) ~= 'table' then
        error("Usage: router:route({ ... }, function(cx) ... end)")
    end

    opts = utils.extend({method = 'ANY'}, opts, false)

    local ctx
    local action

    if sub == nil then
        sub = fs.render
    elseif type(sub) == 'string' then

        ctx, action = string.match(sub, '(.+)#(.*)')

        if ctx == nil or action == nil then
            utils.errorf("Wrong controller format '%s', must be 'module#action'", sub)
        end

        sub = fs.ctx_action

    elseif type(sub) ~= 'function' then
        utils.errorf("wrong argument: expected function, but received %s",
            type(sub))
    end

    opts.method = possible_methods[string.upper(opts.method)] or 'ANY'

    if opts.path == nil then
        error("path is not defined")
    end

    opts.controller = ctx
    opts.action = action
    opts.match = opts.path
    opts.match = string.gsub(opts.match, '[-]', "[-]")

    -- TODO: move to matching.lua
    -- convert user-specified route URL to regexp,
    -- and initialize stashes
    local estash = {  }
    local stash = {  }
    while true do
        local name = string.match(opts.match, ':([%a_][%w_]*)')
        if name == nil then
            break
        end
        if estash[name] then
            utils.errorf("duplicate stash: %s", name)
        end
        estash[name] = true
        opts.match = string.gsub(opts.match, ':[%a_][%w_]*', '([^/]-)', 1)

        table.insert(stash, name)
    end
    while true do
        local name = string.match(opts.match, '[*]([%a_][%w_]*)')
        if name == nil then
            break
        end
        if estash[name] then
            utils.errorf("duplicate stash: %s", name)
        end
        estash[name] = true
        opts.match = string.gsub(opts.match, '[*][%a_][%w_]*', '(.-)', 1)

        table.insert(stash, name)
    end

    -- ensure opts.match is like '^/xxx/$'
    do
        if string.match(opts.match, '.$') ~= '/' then
            opts.match = opts.match .. '/'
        end
        if string.match(opts.match, '^.') ~= '/' then
            opts.match = '/' .. opts.match
        end
        opts.match = '^' .. opts.match .. '$'
    end

    estash = nil

    opts.stash = stash
    opts.sub = sub
    opts.url_for = url_for_route

    -- register new route in a router
    if opts.name ~= nil then
        if opts.name == 'current' then
            error("Route can not have name 'current'")
        end
        if self.iroutes[ opts.name ] ~= nil then
            utils.errorf("Route with name '%s' is already exists", opts.name)
        end
        table.insert(self.routes, opts)
        self.iroutes[ opts.name ] = #self.routes
    else
        table.insert(self.routes, opts)
    end
    return self
end

local function url_for(self, name, args, query)
    local idx = self.iroutes[ name ]
    if idx ~= nil then
        return self.routes[ idx ]:url_for(args, query)
    end

    if string.match(name, '^/') == nil then
        if string.match(name, '^https?://') ~= nil then
            return name
        else
            return '/' .. name
        end
    else
        return name
    end
end

local exports = {
    new = function(options)
        if options == nil then
            options = {}
        end
        if type(options) ~= 'table' then
            utils.errorf("options must be table not '%s'", type(options))
        end

        local default = {
            max_header_size     = 4096,
            header_timeout      = 100,
            app_dir             = '.',
            charset             = 'utf-8',
            cache_templates     = true,
            cache_controllers   = true,
            cache_static        = true,
        }

        local self = {
            options = utils.extend(default, options, true),

            routes      = {  },              -- routes array
            iroutes     = {  },              -- routes by name
            middleware = middleware.new(),   -- new middleware
            helpers = {                      -- for use in templates
                url_for = url_for_helper,
            },
            hooks       = {  },              -- middleware

            -- methods
            use     = use_middleware,  -- new middleware
            route   = add_route,       -- add route
            helper  = set_helper,      -- for use in templates
            hook    = set_hook,        -- middleware
            url_for = url_for,

            -- private
            match   = match_route,

            -- caches
            cache   = {
                tpl         = {},
                ctx         = {},
                static      = {},
            },
        }

        -- make router object itself callable
        --
        -- BE AWARE:
        -- 1) router(env) is valid, but
        -- 2) type(router) == 'table':
        --
        return setmetatable(self, {
            __call = handler,
        })
    end
}

return exports
