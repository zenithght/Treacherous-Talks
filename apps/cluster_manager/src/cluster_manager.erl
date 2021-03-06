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
%%% @doc escript for management of an entire distributed TT cluster
%%%      from the console.
%%% @end
%%%
%%% @since : 24 Nov 2011 by Bermuda Triangle
%%% @end
%%%-------------------------------------------------------------------

-module(cluster_manager).

-include_lib("datatypes/include/clusterconf.hrl").

%% for escript
-export([main/1]).

%% Define default configuration filename
-define(DEFAULT_CONFIG_FILE, "tt.config").

%% Define options list for getopt to use
option_spec_list() ->
    [
     %% {Name, ShortOpt, LongOpt, ArgSpec, HelpMsg}
     {help, $h, "help", undefined, "Show program options"},
     {setconfig, $c, "setconfig", undefined, "Sets all configurations defined in config file"},
     {parallel, $f, "parallel", undefined, "Parallelizes if possible"},
     {join, $j, "join", undefined, "Joins all Riak nodes defined in config file"},
     {ping, $p, "ping", undefined, "Pings all releases defined in config file"},
     {start, $s, "start", undefined, "Starts all releases defined in config file"},
     {stop, $t, "stop", undefined, "Stops all releases defined in config file"},
     {configfile, undefined, undefined, string, "Configuration file (defaults to tt.config if none given)"}
    ].

%% -----------------------------------------------------------------------------
%% @doc
%%  Function that is used to call the cluster manager from command line
%% @end
%% -----------------------------------------------------------------------------
-spec main(term()) -> term().
main(Args) ->
    case getopt:parse(option_spec_list(), Args) of
        {ok, {[], _NonOptionArg}} ->
            usage();
        {ok, {Opts, _NonOptionArg}} ->
            maybe_help(Opts),
            run(Opts);
         {error, _} -> usage()
    end.

run(Opts) ->
    case proplists:get_value(configfile, Opts) of
        undefined -> ConfigFile = ?DEFAULT_CONFIG_FILE;
        Value -> ConfigFile = Value
    end,
    % Get config file
    case file:consult(ConfigFile) of
        {error, Reason} ->
            ErrorString = file:format_error(Reason),
            io:format(standard_error, "~n~s: ~s~n~n", [ErrorString, ConfigFile]),
            usage();
        {ok, [Config]} ->
            os:cmd("epmd -daemon"), % net_kernel needs epmd.
            %% net_kernel needed for distributed erlang.
            net_kernel:start([cluster_manager, longnames]),
            erlang:set_cookie(node(), 'treacherous_talks'),
            ParallelOrder = cluster_utils:parallel_startup_order(Config),
            StartingOrder = cluster_utils:parallel_order_to_serial(ParallelOrder),
            ProcessedConfig = cluster_utils:preprocess_clustconf(Config),
            Parallel = proplists:get_bool(parallel, Opts),

            case proplists:get_bool(setconfig, Opts) of
                true -> cluster_utils:distribute_config(ProcessedConfig);
                false -> ok
            end,
            case proplists:get_bool(start, Opts) of
                true ->
                    case Parallel of
                        false ->
                            cluster_utils:do_action_on_releases(
                              StartingOrder, start_release);
                        true ->
                            cluster_utils:do_parallel_action_on_releases(
                              ParallelOrder, start_release)
                    end,
                    cluster_utils:notify_backends(Config);
                false -> ok
            end,
            case proplists:get_bool(join, Opts) of
                true ->
                    % Filter so that we only get riak releases
                    RiakList = [ {Host, SysMgrPrefix, RelPrefix} ||
                                   {Host, SysMgrPrefix, riak, RelPrefix}
                                       <- StartingOrder],
                    join_riak_nodes(RiakList);
                false -> ok
            end,
            case proplists:get_bool(stop, Opts) of
                true ->
                    case Parallel of
                        false ->
                            ShutdownOrder = lists:reverse(StartingOrder),
                            Res = cluster_utils:do_action_on_releases(
                                    ShutdownOrder, stop_release);
                        true ->
                            ShutdownOrder = [lists:reverse(StartingOrder)],
                            Res = cluster_utils:do_parallel_action_on_releases(
                                    ShutdownOrder, stop_release)
                    end,
                    % Halt and exit with error code on stop error
                    case check_results_for_errors(Res) of
                        ok -> ok;
                        error -> halt(1)
                    end;
                false -> ok
            end,
            case proplists:get_bool(ping, Opts) of
                true ->
                    case Parallel of
                        false ->
                            cluster_utils:do_action_on_releases(
                              StartingOrder, ping_release);
                        true ->
                            cluster_utils:do_parallel_action_on_releases(
                              [StartingOrder], ping_release)
                    end;
                false -> ok
            end
    end.

%% Join all defined riak nodes
-spec join_riak_nodes(list()) ->
    ok | {error, term()} | {badrpc, term()}.
join_riak_nodes([]) -> ok;
join_riak_nodes([{Host, _SysMgrPrefix, RelPrefix}| RiakList]) ->
    % Use the first node in the list as the node all nodes will join
    JoinNode = atom_to_list(RelPrefix) ++ "@"++Host,
    % Make a list that we can feed into do_action_on_releases (yes, we're
    % abusing it a bit, but it is better than duplicating code).
    ReleaseList = [ {Node, SysMgrPre, JoinNode, RelPre} ||
                      {Node, SysMgrPre, RelPre} <- RiakList],
    cluster_utils:do_action_on_releases(ReleaseList, join_riak).

% Helper that checks results lists for any result that returned something else
% than ok
-spec check_results_for_errors(list()) -> ok | error.
check_results_for_errors(Result) ->
    OnlyRes = [ ActionRes || {_Action, _Release, _Host, ActionRes} <- Result ],
    CheckIfOk = fun(Term) ->
                        case Term of
                            ok -> true;
                            _Error -> false
                        end
                end,
    Error = lists:all(CheckIfOk, OnlyRes),
    case Error of
        true -> ok;
        false -> error
    end.

%% Getopt helpers
usage() ->
    usage(option_spec_list()).

usage(OptSpecList) ->
    getopt:usage(OptSpecList, "cluster_manager"),
    halt(127).

maybe_help(Opts) ->
  case proplists:get_bool(help, Opts) of
      true -> usage();
      false -> ok
  end.
