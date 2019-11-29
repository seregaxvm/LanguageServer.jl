T = 0.0

mutable struct LanguageServerInstance
    pipe_in
    pipe_out

    workspaceFolders::Set{String}
    documents::Dict{URI2,Document}

    debug_mode::Bool
    runlinter::Bool
    lint_options::StaticLint.LintOptions
    ignorelist::Set{String}
    isrunning::Bool

    env_path::String
    depot_path::String
    symbol_server::Union{Nothing,SymbolServer.SymbolServerProcess}
    ss_task

    function LanguageServerInstance(pipe_in, pipe_out, debug_mode::Bool = false, env_path = "", depot_path = "")
        new(pipe_in, pipe_out, Set{String}(), Dict{URI2,Document}(), debug_mode, true, StaticLint.LintOptions(), Set{String}(), false, env_path, depot_path, nothing, nothing)
    end
end

function send(message, server)
    message_json = JSON.json(message)

    write_transport_layer(server.pipe_out, message_json, server.debug_mode)
end

function init_symserver(server::LanguageServerInstance)
    wid = last(procs())
    server.debug_mode && @info "Number of processes: ", wid
    
    server.debug_mode && @info "Default DEPOT_PATH: ", server.depot_path
    @fetchfrom wid begin 
        empty!(Base.DEPOT_PATH)
        push!(Base.DEPOT_PATH, server.depot_path)
    end
    server.debug_mode && @info "New DEPOT_PATH: ", @fetchfrom wid Base.DEPOT_PATH
    server.symbol_server = SymbolServer.SymbolServerProcess()
    env_path = server.env_path
    _set_worker_env(env_path, server)
end

function Base.run(server::LanguageServerInstance)
    init_symserver(server)
    
    global T
    while true
        message = read_transport_layer(server.pipe_in, server.debug_mode)
        message_dict = JSON.parse(message)
        # For now just ignore response messages
        if haskey(message_dict, "method")
            server.debug_mode && (T = time())
            request = parse(JSONRPC.Request, message_dict)
            process(request, server)
        end

        # import reloaded package caches
        if server.ss_task !== nothing && isready(server.ss_task)
            uuids = fetch(server.ss_task)
            if !isempty(uuids)
                for uuid in uuids
                    SymbolServer.disc_load(server.symbol_server.context, uuid, server.symbol_server.depot)
                    # should probably re-run linting
                end
                for (uri, doc) in server.documents
                    parse_all(doc, server)
                end
            end
            server.ss_task = nothing
        end
    end
end

function serverbusy(server)
    write_transport_layer(server.pipe_out, JSON.json(Dict("jsonrpc" => "2.0", "method" => "window/setStatusBusy")), server.debug_mode)
end

function serverready(server)
    write_transport_layer(server.pipe_out, JSON.json(Dict("jsonrpc" => "2.0", "method" => "window/setStatusReady")), server.debug_mode)
end

function read_transport_layer(stream, debug_mode = false)
    header_dict = Dict{String,String}()
    line = chomp(readline(stream))
    while length(line) > 0
        h_parts = split(line, ":")
        header_dict[chomp(h_parts[1])] = chomp(h_parts[2])
        line = chomp(readline(stream))
    end
    message_length = parse(Int, header_dict["Content-Length"])
    message_str = String(read(stream, message_length))
    debug_mode && @info "RECEIVED: $message_str"
    debug_mode && @info ""
    return message_str
end

function write_transport_layer(stream, response, debug_mode = false)
    global T
    response_utf8 = transcode(UInt8, response)
    n = length(response_utf8)
    write(stream, "Content-Length: $n\r\n\r\n")
    write(stream, response_utf8)
    debug_mode && @info "SENT: $response"
    debug_mode && @info string("TIME:", round(time()-T, sigdigits = 2))
end

