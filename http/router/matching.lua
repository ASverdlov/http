-- concerns
-- 1. request path - route pattern matching
-- 2. stash

local function transform_filter(filter)
    local path = filter.path  -- luacheck: ignore
    -- route must have '/' at the begin and end
    if string.match(path, '.$') ~= '/' then
        path = path .. '/'
    end
    if string.match(path, '^.') ~= '/' then
        path = '/' .. path
    end

    return {
        path = path,
        method = string.upper(filter.method)
    }
end

-- TODO: creates r.match
local function transform_route_pattern(pattern)

end

local function matches(r, filter)
    local methods_match = r.method == filter.method or r.method == 'ANY'
    if not methods_match then
        return false
    end

    local regex_groups_matched = {string.match(filter.path, r.match)}
    if #regex_groups_matched == 0 then
        return false
    end
    if #r.stash > 0 and #r.stash ~= #regex_groups_matched then
        return false
    end

    return true, {
        route = r,
        stash = regex_groups_matched,
    }
end

local function better_than(newmatch, oldmatch)
    if newmatch == nil then
        return false
    end
    if oldmatch == nil then
        return true
    end

    -- current match (route) is prioritized iff:
    -- 1. it has less matched words, or
    -- 2. if current match (route) has more specific method filter
    if #oldmatch.stash > #newmatch.stash then
        return true
    end
    return newmatch.route.method ~= oldmatch.route.method and
        oldmatch.method == 'ANY'
end

return {
    matches = matches,
    better_than = better_than,
    transform_filter = transform_filter,
    transform_route_pattern = transform_route_pattern,
}
