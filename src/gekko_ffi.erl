-module(gekko_ffi).
-export([run_command/3, get_env/1, find_executable/1, extract_zip_entry/2]).

run_command(Command, Args, Cwd) ->
    CmdStr = unicode:characters_to_list(Command, utf8),
    case resolve_executable(CmdStr) of
        false ->
            {127, <<"Executable not found: ", Command/binary>>};
        Exe ->
            ArgStrs = [unicode:characters_to_list(A, utf8) || A <- Args],
            BaseOpts = [exit_status, stderr_to_stdout, binary, {args, ArgStrs}],
            Opts = case Cwd of
                <<>> -> BaseOpts;
                _ -> [{cd, unicode:characters_to_list(Cwd, utf8)} | BaseOpts]
            end,
            try
                Port = open_port({spawn_executable, Exe}, Opts),
                collect_port(Port, [])
            catch
                error:Reason ->
                    Msg = iolist_to_binary(io_lib:format("Failed to spawn ~s: ~p", [CmdStr, Reason])),
                    {126, Msg}
            end
    end.

resolve_executable(CmdStr) ->
    case lists:member($/, CmdStr) of
        true ->
            case filelib:is_regular(CmdStr) of
                true -> CmdStr;
                false -> false
            end;
        false ->
            os:find_executable(CmdStr)
    end.

collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    end.


get_env(Name) ->
    NameStr = unicode:characters_to_list(Name, utf8),
    case os:getenv(NameStr) of
        false -> {error, nil};
        Val -> {ok, unicode:characters_to_binary(Val)}
    end.

find_executable(Command) ->
    CmdStr = unicode:characters_to_list(Command, utf8),
    case resolve_executable(CmdStr) of
        false -> {error, nil};
        Exe -> {ok, unicode:characters_to_binary(Exe)}
    end.

extract_zip_entry(ZipPath, EntryPath) ->
    ZipStr = unicode:characters_to_list(ZipPath, utf8),
    EntryStr = unicode:characters_to_list(EntryPath, utf8),
    try zip:unzip(ZipStr, [memory, {file_list, [EntryStr]}]) of
        {ok, [{_, Bin}]} when is_binary(Bin) ->
            {ok, Bin};
        {ok, [{_, List}]} when is_list(List) ->
            {ok, list_to_binary(List)};
        _ ->
            {error, nil}
    catch
        _:_ ->
            {error, nil}
    end.
