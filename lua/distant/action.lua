local fn = require('distant.fn')
local g = require('distant.internal.globals')
local session = require('distant.session')
local ui = require('distant.internal.ui')
local u = require('distant.internal.utils')

local action = {}

--- Launches a new instance of the distance binary on the remote machine and sets
--- up a session so clients are able to communicate with it
---
--- @param host string host to connect to (e.g. example.com)
--- @param args table of arguments to append to the launch command, where all
---             keys with _ are replaced with - (e.g. my_key -> --my-key)
--- @return number Exit code once launch has completed, or nil if times out
action.launch = function(host, args)
    assert(type(host) == 'string', 'Missing or invalid host argument')
    args = args or {}

    local buf_h = vim.api.nvim_create_buf(false, true)
    assert(buf_h ~= 0, 'Failed to create buffer for launch')

    local info = vim.api.nvim_list_uis()[1]
    local width = 80
    local height = 8
    local win = vim.api.nvim_open_win(buf_h, 1, {
        relative = 'editor';
        width = width;
        height = height;
        col = (info.width / 2) - (width / 2);
        row = (info.height / 2) - (height / 2);
        anchor = 'NW';
        style = 'minimal';
        border = 'single';
        noautocmd = true;
    })

    -- Format is launch {host} [args..]
    -- NOTE: Because this runs in a pty, all output goes to stdout by default;
    --       so, in order to distinguish errors, we write to a temporary file
    --       when launching so we can read the errors and display a msg
    --       if the launch fails
    local err_log = vim.fn.tempname()
    local cmd_args = u.build_arg_str(u.merge(
        g.settings.launch,
        args,
        {log_file = err_log}
    ))
    vim.fn.termopen(
        g.settings.binary_name .. ' launch ' .. host .. ' ' .. cmd_args,
        {
            on_exit = function(_, code, _)
                vim.api.nvim_win_close(win, false)
                if code ~= 0 then
                    local lines = vim.fn.readfile(err_log)
                    vim.fn.delete(err_log)

                    -- Strip lines of [date/time] ERROR [src/file] prefix
                    lines = u.filter_map(lines, function(line)
                        -- Remove [date/time] and [src/file] parts
                        line = vim.trim(string.gsub(
                            line,
                            '%[[^%]]+%]',
                            ''
                        ))

                        -- Only keep error lines and remove the ERROR prefix
                        if u.starts_with(line, 'ERROR') then
                            return vim.trim(string.sub(line, 6))
                        end
                    end)

                    ui.show_msg(lines, 'err')
                end
            end
        }
    )
end

--- Opens the provided path in one of two ways:
--- 1. If path points to a file, creates a new `distant` buffer with the contents
--- 2. If path points to a directory, displays a dialog with the immediate directory contents
---
--- @param path string Path to directory to show
--- @param all boolean If true, will recursively search directories
--- @param timeout number Maximum time to wait for a response (optional)
--- @param interval number Time in milliseconds to wait between checks for a response (optional)
action.open = function(path, opts)
    assert(type(path) == 'string', 'path must be a string')
    opts = opts or {}

    -- First, we need to figure out if we are working with a file or directory
    local metadata = fn.metadata(path, timeout, interval)
    if metadata == nil then
        return
    end

    -- Second, if the path points to a directory, display a dialog with its contents
    if metadata.file_type == 'dir' then
        local entries = fn.dir_list(path, not (not opts.all), timeout, interval)
        local lines = u.filter_map(entries, function(entry)
            return entry.path
        end)

        if lines ~= nil then
            ui.show_msg(lines)
        end

    -- Third, if path points to a file, establish a buffer with its contents
    elseif metadata.file_type == 'file' then
        -- Load a remote file as text
        local text = fn.read_file_text(path, timeout, interval)

        -- Create a buffer to house the text
        local buf = vim.api.nvim_create_buf(true, false)
        assert(buf ~= 0, 'Failed to create buffer for for remote editing')

        -- Set the content of the buffer to the remote file
        local lines = vim.split(text, '\n', true)
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, lines)

        -- Set buffer name and options to mark it as remote;
        -- writing is handled by an autocmd for the filetype
        vim.api.nvim_buf_set_name(buf, 'distant://' .. path)
        vim.api.nvim_buf_set_option(buf, 'buftype', 'acwrite')
        vim.api.nvim_buf_set_option(buf, 'modified', false)

        -- Add stateful information to the buffer, helping keep track of it
        vim.api.nvim_buf_set_var(buf, 'remote_path', path)

        -- Display the buffer in the specified window, defaulting to current
        vim.api.nvim_win_set_buf(opts.win or 0, buf)

        -- Set our filetype to whatever the contents actually are (or file extension is)
        vim.cmd([[ filetype detect ]])
    else
        vim.api.nvim_err_writeln('Filetype ' .. metadata.file_type .. ' is unsupported')
    end
end

--- Opens a new window to show metadata for some path
---
--- @param path string Path to file/directory/symlink to show
--- @param timeout number Maximum time to wait for a response (optional)
--- @param interval number Time in milliseconds to wait between checks for a response (optional)
action.metadata = function(path, timeout, interval)
    assert(type(path) == 'string', 'path must be a string')

    local metadata = fn.metadata(path, timeout, interval)
    local lines = {}
    table.insert(lines, 'Path: "' .. path .. '"')
    table.insert(lines, 'File Type: ' .. metadata.file_type)
    table.insert(lines, 'Len: ' .. tostring(metadata.len) .. ' bytes')
    table.insert(lines, 'Readonly: ' .. tostring(metadata.readonly))
    if metadata.created ~= nil then
        table.insert(lines, 'Created: ' .. vim.fn.strftime(
            '%c', 
            math.floor(metadata.created / 1000.0)
        ))
    end
    if metadata.accessed ~= nil then
        table.insert(lines, 'Last Accessed: ' .. vim.fn.strftime(
            '%c', 
            math.floor(metadata.accessed / 1000.0)
        ))
    end
    if metadata.modified ~= nil then
        table.insert(lines, 'Last Modified: ' .. vim.fn.strftime(
            '%c', 
            math.floor(metadata.modified / 1000.0)
        ))
    end

    ui.show_msg(lines)
end

--- Opens a new window to display session info
action.info = function()
    local info = session.info()
    ui.show_msg({
        'Host: ' .. info.host;
        'Port: ' .. info.port;
    })
end

return action