-- http.server

local lib = require('http.lib')

local io = io
local require = require
local package = package
local mime_types = require('http.mime_types')
local codes = require('http.codes')

local socket = require('socket')
local fiber = require('fiber')
local json = require('json')
local errno = require 'errno'

local function errorf(fmt, ...)
    error(string.format(fmt, ...))
end

local function printf(fmt, ...)
    print(string.format(fmt, ...))
end

local function sprintf(fmt, ...)
    return string.format(fmt, ...)
end

local function uri_escape(str)
    local res = string.gsub(str, '[^a-zA-Z0-9_]',
        function(c)
            return string.format('%%%02X', string.byte(c))
        end
    )
    return res
end

local function uri_unescape(str)
    local res = string.gsub(str, '%%([0-9a-fA-F][0-9a-fA-F])',
        function(c)
            return string.char(tonumber(c, 16))
        end
    )
    return res
end

local function extend(tbl, tblu, raise)
    local res = {}
    for k, v in pairs(tbl) do
        res[ k ] = v
    end
    for k, v in pairs(tblu) do
        if raise then
            if res[ k ] == nil then
                errorf("Unknown option '%s'", k)
            end
        end
        res[ k ] = v
    end
    return res
end

local function type_by_format(fmt)
    if fmt == nil then
        return 'application/octet-stream'
    end

    local t = mime_types[ fmt ]

    if t ~= nil then
        return t
    end

    return 'application/octet-stream'
end

local function reason_by_code(code)
    code = tonumber(code)
    if codes[code] ~= nil then
        return codes[code]
    end
    return sprintf('Unknown code %d', code)
end

local function ucfirst(str)
    return str:gsub("^%l", string.upper, 1)
end

local function cached_query_param(self, name)
    if name == nil then
        return self.query_params
    end
    return self.query_params[ name ]
end

local function cached_post_param(self, name)
    if name == nil then
        return self.post_params
    end
    return self.post_params[ name ]
end

local request_methods = {
    to_string = function(self)
        local res = self:request_line() .. "\r\n"

        for hn, hv in pairs(self.headers) do
            res = sprintf("%s%s: %s\r\n", res, ucfirst(hn), hv)
        end

        return sprintf("%s\r\n%s", res, self.body)
    end,

    request_line = function(self)
        local rstr = self.path
        if string.len(self.query) then
            rstr = rstr .. '?' .. self.query
        end
        return sprintf("%s %s HTTP/%d.%d",
            self.method, rstr, self.proto[1], self.proto[2])
    end,

    query_param = function(self, name)
        if self.query == nil and string.len(self.query) == 0 then
            rawset(self, 'query_params', {})
        else
            local params = lib.params(self.query)
            local pres = {}
            for k, v in pairs(params) do
                pres[ uri_unescape(k) ] = uri_unescape(v)
            end
            rawset(self, 'query_params', pres)
        end

        rawset(self, 'query_param', cached_query_param)
        return self:query_param(name)
    end,

    post_param = function(self, name)
        if self.headers[ 'content-type' ] == 'multipart/form-data' then
            -- TODO: do that!
            rawset(self, 'post_params', {})
        else
            local params = lib.params(self.body)
            local pres = {}
            for k, v in pairs(params) do
                pres[ uri_unescape(k) ] = uri_unescape(v)
            end
            rawset(self, 'post_params', pres)
        end
        
        rawset(self, 'post_param', cached_post_param)
        return self:post_param(name)
    end,

    param = function(self, name)
        if name ~= nil then
            local v = self:post_param(name)
            if v ~= nil then
                return v
            end
            return self:query_param(name)
        end

        local post = self:post_param()
        local query = self:query_param()
        return extend(post, query, false)
    end
}

local mrequest = {
    __index = function(req, item)
        if item == 'body' then

            if req.s == nil then
                rawset(req, 's', nil)
                rawset(req, 'body', '')
                return ''
            end

            if req.headers['content-length'] == nil then
                rawset(req, 's', nil)
                rawset(req, 'body', '')
                return ''
            end

            local cl = tonumber(req.headers['content-length'])

            if cl == 0 then
                rawset(req, 's', nil)
                rawset(req, 'body', '')
                return ''
            end

            local body, status, eno, estr = req.s:read(cl)

            if status ~= nil then
                printf("Can't read request body: %s %s", status, estr)
                rawset(req, 's', nil)
                rawset(req, 'body', '')
                rawset(req, 'broken', true)
                return ''
            end
            rawset(req, 's', nil)
            if body ~= nil then
                rawset(req, 'body', body)
                return body
            else
                rawset(req, 'body', '')
                return ''
            end
        end

        if item == 'json' then
            local s, json = pcall(json.decode, req.body)
            if s then
                rawset(req, 'json', json)
                return json
            else
                printf("Can't decode json in request '%s': %s",
                    req:request_line(), json)
                return nil
            end
        end
    end
}

local parse_request = function(str)
    local req = lib._parse_request(str)
    if req.error ~= nil then
        return req
    end

    rawset(req, 'broken', false)

    for m, f in pairs(request_methods) do
        req[ m ] = f
    end


    setmetatable(req, mrequest)

    return req
end

local function catfile(...)
    local sp = { ... }

    local path

    if #sp == 0 then
        return
    end

    for i, pe in pairs(sp) do
        if path == nil then
            path = pe
        elseif string.match(path, '.$') ~= '/' then
            if string.match(pe, '^.') ~= '/' then
                path = path .. '/' .. pe
            else
                path = path .. pe
            end
        else
            if string.match(pe, '^.') == '/' then
                path = path .. string.gsub(pe, '^/', '', 1)
            else
                path = path .. pe
            end
        end
    end

    return path
end

local function log(peer, code, req, len)
    if req == nil then
        len = 0
        req = '-'
    else
        if len == nil then
            len = 0
        end
    end

    printf("%s - - \"%s\" %s %s\n", peer, req, code, len)
end

local function hlog(peer, code, hdr)
    if string.len(hdr) == 0 then
        return log(peer, code)
    end
    local rs = string.match(hdr, "^(.-)[\r\n]")
    if rs == nil then
        return log(peer, code, hdr)
    else
        return log(peer, code, rs)
    end
end

local function expires_str(str)

    local now = os.time()
    local gmtnow = now - os.difftime(now, os.time(os.date("!*t", now)))
    local fmt = '%a, %d-%b-%Y %H:%M:%S GMT'

    if str == 'now' or str == 0 or str == '0' then
        return os.date(fmt, gmtnow)
    end

    local diff, period = string.match(str, '^[+]?(%d+)([hdmy])$')
    if period == nil then
        return str
    end

    diff = tonumber(diff)
    if period == 'h' then
        diff = diff * 3600
    elseif period == 'd' then
        diff = diff * 86400
    elseif period == 'm' then
        diff = diff * 86400 * 30
    else
        diff = diff * 86400 * 365
    end

    return os.date(fmt, gmtnow + diff)
end

local function set_cookie(tx, cookie)
    local name = cookie.name
    local value = cookie.value

    if name == nil then
        error('cookie.name is undefined')
    end
    if value == nil then
        error('cookie.value is undefined')
    end

    local str = sprintf('%s=%s', name, uri_escape(value))
    if cookie.path ~= nil then
        str = sprintf('%s;path=%s', str, uri_escape(cookie.path))
    else
        str = sprintf('%s;path=%s', str, tx.req.path)
    end
    if cookie.domain ~= nil then
        str = sprintf('%s;domain=%s', str, domain)
    end

    if cookie.expires ~= nil then
        str = sprintf('%s;expires="%s"', str, expires_str(cookie.expires))
    end

    if tx.resp.headers['set-cookie'] == nil then
        tx.resp.headers['set-cookie'] = { str }
    elseif type(tx.resp.headers['set-cookie']) == 'string' then
        tx.resp.headers['set-cookie'] = {
            tx.resp.headers['set-cookie'],
            str
        }
    else
        table.insert(tx.resp.headers['set-cookie'], str)
    end
    return str
end

local function cookie(tx, cookie)
    if type(cookie) == 'table' then
        return set_cookie(tx, cookie)
    end
    
    if tx.req.headers.cookie == nil then
        return nil
    end
    for k, v in string.gmatch(
                tx.req.headers.cookie, "([^=,; \t]+)=([^,; \t]+)") do
        if k == cookie then
            return uri_unescape(v)
        end
    end
    return nil
end

local function url_for_helper(tx, name, args, query)
    return tx:url_for(name, args, query)
end

local function load_template(self, r, format)
    if r.template ~= nil then
        return
    end

    if format == nil then
        format = 'html'
    end

    local file
    if r.file ~= nil then
        file = r.file
    elseif r.controller ~= nil and r.action ~= nil then
        file = catfile(
            string.gsub(r.controller, '[.]', '/'),
            r.action .. '.' .. format .. '.el')
    else
        errorf("Can not find template for '%s'", r.path)
    end
    
    if self.options.cache_templates then
        if self.cache.tpl[ file ] ~= nil then
            return self.cache.tpl[ file ]
        end
    end


    local tpl = catfile(self.options.app_dir, 'templates', file)
    local fh = io.input(tpl)
    local template = fh:read('*a')
    fh:close()

    if self.options.cache_templates then
        self.cache.tpl[ file ] = template
    end
    return template
end


local function render(tx, opts)
    if tx == nil then
        error("Usage: self:render({ ... })")
    end

    local vars = {}
    if opts ~= nil then
        if opts.text ~= nil then
            if tx.httpd.options.charset ~= nil then
                tx.resp.headers['content-type'] =
                    sprintf("text/plain; charset=%s",
                        tx.httpd.options.charset
                    )
            else
                tx.resp.headers['content-type'] = 'text/plain'
            end
            tx.resp.body = tostring(opts.text)
            return
        end

        if opts.json ~= nil then
            if tx.httpd.options.charset ~= nil then
                tx.resp.headers['content-type'] =
                    sprintf('application/json; charset=%s',
                        tx.httpd.options.charset
                    )
            else
                tx.resp.headers['content-type'] = 'application/json'
            end
            tx.resp.body = json.encode(opts.json)
            return
        end

        if opts.data ~= nil then
            tx.resp.body = tostring(data)
            return
        end

        vars = extend(tx.tstash, opts, false)
    end
    
    local tpl

    local format = tx.tstash.format
    if format == nil then
        format = 'html'
    end
    
    if tx.endpoint.template ~= nil then
        tpl = tx.endpoint.template
    else
        tpl = load_template(tx.httpd, tx.endpoint, format)
        if tpl == nil then
            errorf('template is not defined for the route')
        end
    end

    if type(tpl) == 'function' then
        tpl = tpl()
    end

    for hname, sub in pairs(tx.httpd.helpers) do
        vars[hname] = function(...) return sub(tx, ...) end
    end
    vars.action = tx.endpoint.action
    vars.controller = tx.endpoint.controller
    vars.format = format

    tx.resp.body = lib.template(tpl, vars)
    tx.resp.headers['content-type'] = type_by_format(format)

    if tx.httpd.options.charset ~= nil then
        if format == 'html' or format == 'js' or format == 'json' then
            tx.resp.headers['content-type'] = tx.resp.headers['content-type']
                .. '; charset=' .. tx.httpd.options.charset
        end
    end
end

local function iterate(tx, gen, param, state)
    tx.resp.body = { gen = gen, param = param, state = state }
end

local function redirect_to(tx, name, args, query)
    tx.resp.headers.location = tx:url_for(name, args, query)
    tx.resp.status = 302
end

local function access_stash(tx, name, ...)
    if type(tx) ~= 'table' then
        error("usage: ctx:stash('name'[, 'value'])")
    end
    if select('#', ...) > 0 then
        tx.tstash[ name ] = select(1, ...)
    end

    return tx.tstash[ name ]
end

local function url_for_tx(tx, name, args, query)
    if name == 'current' then
        return tx.endpoint:url_for(args, query)
    end
    return tx.httpd:url_for(name, args, query)
end

local function static_file(self, request, format)
        local file = catfile(self.options.app_dir, 'public', request.path)

        if self.options.cache_static and self.cache.static[ file ] ~= nil then
            return {
                code = 200,
                headers = {
                    [ 'content-type'] = type_by_format(format),
                },
                body = self.cache.static[ file ]
            }
        end

        local s, fh = pcall(io.input, file)

        if not s then
            return { code = 404 }
        end

        local body = fh:read('*a')
        io.close(fh)

        if self.options.cache_static then
            self.cache.static[ file ] = body
        end

        return {
            code = 200,
            headers = {
                [ 'content-type'] = type_by_format(format),
            },
            body = body
        }
end

local function handler(self, request)

    if self.hooks.before_routes ~= nil then
        self.hooks.before_dispatch(self, request)
    end

    local format = 'html'

    local pformat = string.match(request.path, '[.]([^.]+)$')
    if pformat ~= nil then
        format = pformat
    end


    local r = self:match(request.method, request.path)
    if r == nil then
        return static_file(self, request, format)
    end

    local stash = extend(r.stash, { format = format })

    local resp = { headers = {}, code = 200 }

    local tx = {
        req         = request,
        resp        = resp,
        endpoint    = r.endpoint,
        tstash      = stash,
        render      = render,
        cookie      = cookie,
        redirect_to = redirect_to,
        iterate     = iterate,
        httpd       = self,
        stash       = access_stash,
        url_for     = url_for_tx
    }

    r.endpoint.sub( tx )

    if self.hooks.after_dispatch ~= nil then
        self.hooks.after_dispatch(tx, resp)
    end

    return resp
end

local function normalize_headers(hdrs)
    local res = {}
    for h, v in pairs(hdrs) do
        res[ string.lower(h) ] = v
    end
    return res
end

local function process_client(self, s)
    local peer = s:peer()
    while true do


        local hdrs = s:read{
            chunk = self.options.max_header_size,
            delimiter = { "\n\n", "\r\n\r\n" }
        }

        local p = parse_request(hdrs)
        if rawget(p, 'error') ~= nil then
            if rawget(p, 'method') ~= nil then
                log(peer, 400, p:request_line())
            else
                hlog(peer, 400, hdrs)
            end
            s:write(sprintf("HTTP/1.0 400 Bad request\r\n\r\n%s", p.error))
            break
        end
        rawset(p, 'peer', peer)

        -- first access at body will load body
        if p.method ~= 'GET' then
            rawset(p, 'body', nil)
            rawset(p, 's', s)
        end

        local status, reason = pcall(self.options.handler, self, p)
        local code, hdrs, body

        if not status then
            code = 500
            hdrs = {}
            body =
                  "Unhandled error:\n"
                .. debug.traceback(reason) .. "\n\n"

                .. "\n\nRequest:\n"
                .. p:to_string()
        else
            code = reason.code or 200
            hdrs = reason.headers
            body = reason.body

            if hdrs == nil then
                hdrs = {}
            elseif type(hdrs) ~= 'table' then
                code = 500
                hdrs = {}
                body = sprintf(
                    'Handler returned non-table headers: %s',
                    type(hdrs)
                )
            end
        end

        hdrs = normalize_headers(hdrs)

        local gen, param, state
        if type(body) == 'string' then
            -- Plain string
            hdrs['content-length'] = #body
        elseif type(body) == 'function' then
            -- Generating function
            gen = body
            hdrs['transfer-encoding'] = 'chunked'
        elseif type(body) == 'table' and body.gen then
            -- Iterator
            gen, param, state = body.gen, body.param, body.state
            hdrs['transfer-encoding'] = 'chunked'
        elseif body == nil then
            -- Empty body
            hdrs['content-length'] = 0
        else
            body = tostring(body)
            hdrs['content-length'] = #body
        end

        if hdrs.server == nil then
            local title = 'Tarantool http-server v1'
            if rawget(box, 'info') ~= nil then
                title = title .. sprintf(' (tarantool v%s)', box.info.version)
            end
            hdrs.server = title
        end

        if p.proto[1] ~= 1 then
            hdrs.connection = 'close'
        elseif p.broken then
            hdrs.connection = 'close'
        elseif rawget(p, 'body') == nil then
            hdrs.connection = 'close'
        elseif p.proto[2] == 1 then
            if p.headers.connection == nil then
                hdrs.connection = 'keep-alive'
            elseif string.lower(p.headers.connection) ~= 'keep-alive' then
                hdrs.connection = 'close'
            else
                hdrs.connection = 'keep-alive'
            end
        elseif p.proto[2] == 0 then
            if p.headers.connection == nil then
                hdrs.connection = 'close'
            elseif string.lower(p.headers.connection) == 'keep-alive' then
                hdrs.connection = 'keep-alive'
            else
                hdrs.connection = 'close'
            end
        end

        local hdr = ''
        for k, v in pairs(hdrs) do
            if type(v) == 'table' then
                for i, sv in pairs(v) do
                    hdr = hdr .. sprintf("%s: %s\r\n", ucfirst(k), sv)
                end
            else
                hdr = hdr .. sprintf("%s: %s\r\n", ucfirst(k), v)
            end
        end

        s:write(sprintf(
            "HTTP/1.1 %s %s\r\n%s\r\n",
            code,
            reason_by_code(code),
            hdr
        ))

        if type(body) == 'string' then
            s:write(body)
        elseif gen then
            -- Transfer-Encoding: chunked
            for _, part in gen, param, state do
                part = tostring(part)
                s:write(sprintf("%x\r\n", #part))
                s:write(part)
                s:write("\r\n")
            end
            s:write("0\r\n\r\n")
        end

        if p.proto[1] ~= 1 then
            break
        end

        if hdrs.connection ~= 'keep-alive' then
            break
        end
    end
    s:close()
end

local function httpd_stop(self)
   if type(self) ~= 'table' then
       error("httpd: usage: httpd:stop()")
    end
    if self.is_run then
        self.is_run = false
    else
        error("server is already stopped")
    end

    if self.tcp_server ~= nil then
        self.tcp_server:close()
        self.tcp_server = nil
    end
    return self
end

local function match_route(self, method, route)

    -- format
    route = string.gsub(route, '([^/])[.][^.]+$', '%1')
    
    -- route must have '/' at the begin and end
    if string.match(route, '.$') ~= '/' then
        route = route .. '/'
    end
    if string.match(route, '^.') ~= '/' then
        route = '/' .. route
    end

    method = string.upper(method)

    local fit
    local stash = {}

    for k, r in pairs(self.routes) do
        if r.method == method or r.method == 'ANY' then
            local m = { string.match(route, r.match)  }
            local nfit
            if #m > 0 then
                if #r.stash > 0 then
                    if #r.stash == #m then
                        nfit = r
                    end
                else
                    nfit = r
                end

                if nfit ~= nil then
                    if fit == nil then
                        fit = nfit
                        stash = m
                    else
                        if #fit.stash > #nfit.stash then
                            fit = nfit
                            stash = m
                        elseif r.method ~= fit.method then
                            if fit.method == 'ANY' then
                                fit = nfit
                                stash = m
                            end
                        end
                    end
                end
            end
        end
    end

    if fit == nil then
        return fit
    end
    local resstash = {}
    for i = 1, #fit.stash do
        resstash[ fit.stash[ i ] ] = stash[ i ]
    end
    return  { endpoint = fit, stash = resstash }
end

local function set_helper(self, name, sub)
    if sub == nil or type(sub) == 'function' then
        self.helpers[ name ] = sub
        return self
    end
    errorf("Wrong type for helper function: %s", type(sub))
end

local function set_hook(self, name, sub)
    if sub == nil or type(sub) == 'function' then
        self.hooks[ name ] = sub
    end
    errorf("Wrong type for hook function: %s", type(sub))
end

local function url_for_route(r, args, query)
    if args == nil then
        args = {}
    end
    name = r.path
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
                name = name .. sep .. uri_escape(k) .. '=' .. uri_escape(v)
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

local function ctx_action(tx)
    local ctx = tx.endpoint.controller
    local action = tx.endpoint.action
    if tx.httpd.options.cache_controllers then
        if tx.httpd.cache[ ctx ] ~= nil then
            if type(tx.httpd.cache[ ctx ][ action ]) ~= 'function' then
                errorf("Controller '%s' doesn't contain function '%s'",
                    ctx, action)
            end
            tx.httpd.cache[ ctx ][ action ](tx)
            return
        end
    end

    local ppath = package.path
    package.path = catfile(tx.httpd.options.app_dir, 'controllers', '?.lua')
                .. ';'
                .. catfile(tx.httpd.options.app_dir,
                    'controllers', '?/init.lua')
    if ppath ~= nil then
        package.path = package.path .. ';' .. ppath
    end

    local st, mod = pcall(require, ctx)
    package.path = ppath
    package.loaded[ ctx ] = nil

    if not st then
        errorf("Can't load module '%s': %s'", ctx, mod)
    end

    if type(mod) ~= 'table' then
        errorf("require '%s' didn't return table", ctx)
    end

    if type(mod[ action ]) ~= 'function' then
        errorf("Controller '%s' doesn't contain function '%s'", ctx, action)
    end

    if tx.httpd.options.cache_controllers then
        tx.httpd.cache[ ctx ] = mod
    end

    mod[action](tx)
end

local function add_route(self, opts, sub)
    if type(opts) ~= 'table' or type(self) ~= 'table' then
        error("Usage: httpd:route({ ... }, function(cx) ... end)")
    end

    opts = extend({method = 'ANY'}, opts, false)
    
    local ctx
    local action

    if sub == nil then
        sub = function(cx) cx:render() end
    elseif type(sub) == 'string' then

        ctx, action = string.match(sub, '(.+)#(.*)')

        if ctx == nil or action == nil then
            errorf("Wrong controller format '%s', must be 'module#action'", sub)
        end

        sub = ctx_action
        
    elseif type(sub) ~= 'function' then
        errorf("wrong argument: expected function, but received %s",
            type(sub))
    end


    opts.method = string.upper(opts.method)

    if opts.method ~= 'GET' and opts.method ~= 'POST' then
        opts.method = 'ANY'
    end

    if opts.path == nil then
        error("path is not defined")
    end

    opts.controller = ctx
    opts.action = action
    opts.match = opts.path
    opts.match = string.gsub(opts.match, '[-]', "[-]")

    local estash = {  }
    local stash = {  }
    while true do
        local name = string.match(opts.match, ':([%a_][%w_]*)')
        if name == nil then
            break
        end
        if estash[name] then
            errorf("duplicate stash: %s", name)
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
            errorf("duplicate stash: %s", name)
        end
        estash[name] = true
        opts.match = string.gsub(opts.match, '[*][%a_][%w_]*', '(.-)', 1)

        table.insert(stash, name)
    end

    if string.match(opts.match, '.$') ~= '/' then
        opts.match = opts.match .. '/'
    end
    if string.match(opts.match, '^.') ~= '/' then
        opts.match = '/' .. opts.match
    end

    opts.match = '^' .. opts.match .. '$'

    estash = nil

    opts.stash = stash
    opts.sub = sub
    opts.url_for = url_for_route

    if opts.name ~= nil then
        if opts.name == 'current' then
            error("Route can not have name 'current'")
        end
        if self.iroutes[ opts.name ] ~= nil then
            errorf("Route with name '%s' is already exists", opts.name)
        end
        table.insert(self.routes, opts)
        self.iroutes[ opts.name ] = #self.routes
    else
        table.insert(self.routes, opts)
    end
    return self
end

local function url_for_httpd(httpd, name, args, query)
    
    local idx = httpd.iroutes[ name ]
    if idx ~= nil then
        return httpd.routes[ idx ]:url_for(args, query)
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

local function httpd_start(self)
    if type(self) ~= 'table' then
        error("httpd: usage: httpd:start()")
    end

    local server = socket.tcp_server(self.host, self.port,
        function(...) process_client(self, ...) end)
    if server == nil then
        error(sprintf("Can't create tcp_server: %s", errno.strerror()))
    end

    rawset(self, 'is_run', true)
    rawset(self, 'tcp_server', server)
    rawset(self, 'stop', httpd_stop)

    return self
end

local exports = {
    new = function(host, port, options)
        if options == nil then
            options = {}
        end
        if type(options) ~= 'table' then
            errorf("options must be table not '%s'", type(options))
        end
        local default = {
            max_header_size     = 4096,
            header_timeout      = 100,
            handler             = handler,
            app_dir             = '.',
            charset             = 'utf-8',
            cache_templates     = true,
            cache_controllers   = true,
            cache_static        = true,
        }

        local self = {
            host    = host,
            port    = port,
            is_run  = false,
            stop    = httpd_stop,
            start   = httpd_start,
            options = extend(default, options, true),

            routes  = {  },
            iroutes = {  },
            helpers = {
                url_for = url_for_helper,
            },
            hooks   = {  },

            -- methods
            route   = add_route,
            match   = match_route,
            helper  = set_helper,
            hook    = set_hook,
            url_for = url_for_httpd,

            -- caches
            cache   = {
                tpl         = {},
                ctx         = {},
                static      = {},
            },
        }

        return self
    end,

    parse_request = parse_request
}

return exports
