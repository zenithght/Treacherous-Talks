%%%-------------------------------------------------------------------
%%% @copyright
%%% Copyright (C) 2011 by Bermuda Triangle
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.
%%% @end
%%%-------------------------------------------------------------------
%%% @author Erik Timan <erol7391@student.uu.se>
%%%
%%% @doc The system manager application handles configuration of the Treacherous
%%% Talks system. It is intended to be the single point of entry for configuring
%%% and controlling the whole system on a server.
%%%
%%% @end
%%%
%%% @since : 23 Nov 2011 by Bermuda Triangle
%%% @end
%%%-------------------------------------------------------------------
-module(system_manager).

-behaviour(gen_server).

-include_lib("datatypes/include/clusterconf.hrl").

-include_lib("utils/include/debug.hrl").

%% Set a timeout for API calls.
-define(TIMEOUT, 30000).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/0, update_config/1, start_release/1, stop_release/1,
        ping_release/1, join_riak/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% @doc
%% Update all the config files needed to fulfill the given host configuration
%% tuple.
%%
%% @end
%% ------------------------------------------------------------------
-spec update_config(hostconf()) -> ok | {error, term()}.
update_config(HostConfig) ->
    gen_server:call(?MODULE, {update_config, HostConfig}, ?TIMEOUT).

%% ------------------------------------------------------------------
%% @doc
%% Starts a given release and returns as soon as it is possible to ping the
%% VM. Please notice that this does not ensure that any applications has
%% started correctly.
%%
%% @end
%% ------------------------------------------------------------------
-spec start_release(relname()) -> ok | {error, term()}.
start_release(Relname) ->
    gen_server:call(?MODULE, {start_release, Relname}, ?TIMEOUT).

%% ------------------------------------------------------------------
%% @doc
%% Stops a given release and returns only when the release has been truly
%% stopped (VM is shutdown).
%%
%% @end
%% ------------------------------------------------------------------
-spec stop_release(relname()) -> ok | {error, term()}.
stop_release(Relname) ->
    gen_server:call(?MODULE, {stop_release, Relname}, ?TIMEOUT).

%% ------------------------------------------------------------------
%% @doc
%% Pings a given release and returns the result.
%%
%% @end
%% ------------------------------------------------------------------
-spec ping_release(relname()) -> up | down | {error, term()}.
ping_release(Relname) ->
    gen_server:call(?MODULE, {ping_release, Relname}, ?TIMEOUT).

%% ------------------------------------------------------------------
%% @doc
%% Adds the local Riak node to a cluster by sending a join request to the given
%% Node.
%%
%% @end
%% ------------------------------------------------------------------
-spec join_riak(hostname()) -> ok | {error, term()}.
join_riak(Node) ->
    gen_server:call(?MODULE, {join_riak, Node}, ?TIMEOUT).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([]) ->
    process_flag(trap_exit, true),
    {ok, {}}.

handle_call(ping, _From, State) ->
    {reply, {pong, self()}, State};
handle_call({update_config, HostConfig}, _From, State) ->
    {reply, int_update_config(HostConfig), State};
handle_call({start_release, riak=Relname}, _From, State) ->
    ok = save_status_of_release(Relname, started),
    Reply = case int_start_release(Relname) of
                ok ->
                    {ok, Releasepath} = application:get_env(release_path),
                    add_riak_search_schemas(Releasepath);
                Error ->
                    Error
    end,
    {reply, Reply, State};
handle_call({start_release, Relname}, _From, State) ->
    ok = save_status_of_release(Relname, started),
    {reply, int_start_release(Relname), State};
handle_call({stop_release, Relname}, _From, State) ->
    ok = save_status_of_release(Relname, stopped),
    {reply, int_stop_release(Relname), State};
handle_call({ping_release, Relname}, _From, State) ->
    {reply, handle_releases:ping_release(Relname), State};
handle_call({join_riak, Node}, _From, State) ->
    {reply, int_join_riak(Node), State}.

handle_cast(_Msg, State) ->
    io:format ("received unhandled cast: ~p~n",[{_Msg, State}]),
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(shutdown, _State) ->
    {ok, Releases} = get_started_releases(),
    ?DEBUG("Shutting down the following releases: ~p~n", [Releases]),
    [ int_stop_release(Release) || Release <- Releases ],
    ok;
terminate(_Reason, _State) ->
    io:format ("[~p] terminated ~p: reason: ~p, state: ~p ~n",
               [?MODULE, self(), _Reason, _State]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Functions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% @doc
%% Applies a given host configuration tuple to local releases.
%%
%% @end
%% ------------------------------------------------------------------
-spec int_update_config(hostconf()) -> ok | {error, term()}.
int_update_config(HostConfig) ->
    {ok, Releasepath} = application:get_env(release_path),
    case HostConfig of
        {host, Hostname, RelConfs} ->
            update_app_config_loop(RelConfs, Hostname, Releasepath)
    end.

%% ------------------------------------------------------------------
%% @doc
%% Iterates over given release configurations and applies them to each release
%% in turn.
%%
%% @end
%% ------------------------------------------------------------------
-spec update_app_config_loop([relconf()], hostname(), string()) ->
    ok | {error, term()}.
update_app_config_loop([], _Hostname, _Releasepath) ->
    ok;
update_app_config_loop([Config | T], Hostname, Releasepath) ->
    case Config of
        {release, riak=Relname, RelConf} ->
            ok = update_app_config(Releasepath, Relname, RelConf),
            ok = update_node_name(Releasepath, Hostname, Relname, "vm.args"),
            % Call ourself again
            update_app_config_loop(T, Hostname, Releasepath);
        {release, Relname, RelConf} ->
            ok = update_app_config(Releasepath, Relname, RelConf),
            ok = update_node_name(Releasepath, Hostname, Relname, "nodename"),
            % Call ourself again
            update_app_config_loop(T, Hostname, Releasepath);
        _ ->
            {error, badconfig}
    end.

%% ------------------------------------------------------------------
%% @doc
%% Merges the given configuration with the configuration already present in the
%% app.config.old file in a release and writes it to app.config.
%%
%% If the app.config.old file is not present (like on first run), copy
%% app.config to app.config.old.
%%
%% @end
%% ------------------------------------------------------------------
-spec update_app_config(string(), relname(), relconf()) ->
    ok | {error, term()}.
update_app_config(Releasepath, Relname, RelConf) ->
    Path = filename:join([Releasepath, Relname, "etc"]),
    AppFile = filename:join([Path, "app.config"]),
    OldAppFile = filename:join([Path, "app.config.old"]),
    % If there is a "old" app.config file, use that, otherwise copy the regular
    % app.config to .old to preserve the default options.
    case filelib:is_regular(OldAppFile) of
        true -> ok;
        false -> {ok, _Bytes} = file:copy(AppFile, OldAppFile)
    end,
    % Get old app.config, merge with new and write to app.config
    {ok, OldConfig} = manage_config:read_config(OldAppFile),
    NewConfig = manage_config:update_config(OldConfig, RelConf),
    manage_config:write_config(AppFile, NewConfig).

%% ------------------------------------------------------------------
%% @doc
%% Replaces the -name variable in the given file in etc/ for a given release.
%%
%% @end
%% ------------------------------------------------------------------
-spec update_node_name(string(), hostname(), relname(), string()) ->
    ok | {error, term()}.
update_node_name(Releasepath, Hostname, Relname, Filename) ->
    Path = filename:join([Releasepath, Relname, "etc", Filename]),
    Namestring = "-name "++atom_to_list(Relname)++"@"++Hostname,
    case file:read_file(Path) of
        {ok, Data} ->
            NewD = re:replace(Data, "-name .*", Namestring, [{return,iodata}]),
            file:write_file(Path, NewD);
        Other ->
            Other
    end.

%% ------------------------------------------------------------------
%% @doc
%% Adds all search schemas in the RELEASEPATH/backend/riak to the running Riak
%% instance.
%%
%% @end
%% ------------------------------------------------------------------
-spec add_riak_search_schemas(string()) -> ok | {error, term()}.
add_riak_search_schemas(Releasepath) ->
    SchemaDir = filename:join([Releasepath, "backend", "riak"]),
    SchemaFiles = filelib:wildcard("*.schema", SchemaDir),
    add_riak_search_schemas_loop(SchemaDir, SchemaFiles).


%% ------------------------------------------------------------------
%% @doc
%% Loops over the given filename list and calls add_riak_search_schema for each
%% one.
%%
%% @end
%% ------------------------------------------------------------------
-spec add_riak_search_schemas_loop(string(), list()) ->
    ok | {error, term()}.
add_riak_search_schemas_loop(_SchemaDir, []) ->
    ok;
add_riak_search_schemas_loop(SchemaDir, [Filename | T]) ->
    case add_riak_search_schema(SchemaDir, Filename) of
        ok ->
            add_riak_search_schemas_loop(SchemaDir, T);
        Other ->
            Other
    end.

%% ------------------------------------------------------------------
%% @doc
%% Adds one search schema to Riak given the filename of a schema and the schema
%% directory. The filename of the schema is assumed to be SCHEMA_NAME.schema
%% where SCHEMA_NAME is used for the install command.
%%
%% @end
%% ------------------------------------------------------------------
-spec add_riak_search_schema(string(), string()) ->
    ok | {error, term()}.
add_riak_search_schema(SchemaDir, Filename) ->
    SchemaFile = filename:absname(filename:join([SchemaDir, Filename])),
    % Remove the .schema extension to get the schema name
    SchemaName = re:replace(Filename, "\.schema", "", [{return, list}]),
    SetSchema = ["set-schema ", SchemaName, " ", SchemaFile],
    case handle_releases:run_riak_search_command(["install ", SchemaName]) of
        {ok, _Text} ->
            ?DEBUG("Got return from search-cmd: ~p.~n", [_Text]),
            case handle_releases:run_riak_search_command(SetSchema) of
                {ok, _Text2} ->
                    ?DEBUG("Got return from search-cmd: ~p.~n", [_Text2]),
                    ok;
                Other ->
                    Other
            end;
        Other ->
            Other
    end.

%% ------------------------------------------------------------------
%% @doc
%% Starts a given release and pings it to ensure that it is started. If the
%% release already was started, we return an error.
%%
%% @end
%% ------------------------------------------------------------------
-spec int_start_release(relname()) -> ok | {error, term()}.
int_start_release(Relname) ->
    case handle_releases:ping_release(Relname) of
        up ->
            % Crap, it is already started.
            {error, release_is_already_started};
        down ->
            % Ok, do regular start and try to ping it up to 15 times
            case handle_releases:start_release(Relname) of
                {ok, _Text} ->
                    case handle_releases:ping_release_and_wait(Relname, 15) of
                        up ->
                            ok;
                        down ->
                            {error, release_ping_timed_out};
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% ------------------------------------------------------------------
%% @doc
%% Stops a given release. If it is already stopped, this function will still
%% return ok.
%%
%% @end
%% ------------------------------------------------------------------
-spec int_stop_release(relname()) -> ok | {error, term()}.
int_stop_release(Relname) ->
    case handle_releases:ping_release(Relname) of
        up ->
            case handle_releases:stop_release(Relname) of
                {ok, _Text} ->
                    ok;
                Error ->
                    Error
            end;
        down ->
            ok;
        Error ->
            Error
    end.

%% ------------------------------------------------------------------
%% @doc
%% Joins our local Riak release to a Riak cluster by sending a join request to
%% Node.
%%
%% @end
%% ------------------------------------------------------------------
-spec int_join_riak(hostname()) -> ok | {error, term()}.
int_join_riak(Node) ->
    case handle_releases:run_riak_join_command(Node) of
        {ok, _Text} ->
            ok;
        Error ->
            Error
    end.

%% ------------------------------------------------------------------
%% @doc
%% Saves the current status of a release to the file status-of-releases in the
%% log directory. It updates the information in the file as needed.
%%
%% @end
%% ------------------------------------------------------------------
-spec save_status_of_release(relname(), atom()) ->
    ok | {error, term()}.
save_status_of_release(Relname, Status) ->
    Filename = filename:join(["log", "status-of-releases"]),
    ?DEBUG("Saving status ~p of release ~p.~n", [Status, Relname]),
    % See if we can read the old status
    case manage_config:read_config(Filename) of
        {ok, OldList} ->
            NewList = update_rel_status(OldList, [{Relname, Status}]),
            manage_config:write_config(Filename, NewList);
        {error, enoent} ->
            % No old file, nothing to merge. Just write to a new one.
            manage_config:write_config(Filename, [{Relname, Status}]);
        Other ->
            Other
    end.

%% ------------------------------------------------------------------
%% @doc
%% Gets a list of started releases by reading and parsing the file
%% status-of-releases.
%%
%% @end
%% ------------------------------------------------------------------
-spec get_started_releases() -> {ok, list()} | {error, term()}.
get_started_releases() ->
    Filename = filename:join(["log", "status-of-releases"]),
    case manage_config:read_config(Filename) of
        {ok, List} ->
            % Get a list of the started releases by going through the list and
            % matching on started ones.
            {ok, [Release || {Release, started} <- List]};
        {error, enoent} ->
            {ok, []};
        Other ->
            Other
    end.

%% ------------------------------------------------------------------
%% @doc
%%  Given a list of tuples [{relname, status}] and a list of changes,
%%  do a lists:keystore on each change so that existing releases
%%  are replaced, and new releases are insterted.
%% @end
%% ------------------------------------------------------------------
-spec update_rel_status([{atom(), atom()}], [{atom(), atom()}]) -> [{atom(), atom()}].
update_rel_status(OldStatuses, StatusChanges) ->
    Fun = fun({RelName, Change}, Config) ->
                  lists:keystore(RelName, 1, Config, {RelName, Change})
          end,
    lists:foldl(Fun, OldStatuses, StatusChanges).
