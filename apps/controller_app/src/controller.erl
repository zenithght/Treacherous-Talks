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
%%% @author Tiina Loukusa <loukusa@gmail.com>
%%%
%%% @doc Provides an API for the Treacherous Talks frontend
%%% @end
%%%
%%% @since : 17 Oct 2011 by Bermuda Triangle
%%% @end
%%%-------------------------------------------------------------------
-module(controller).

%% Public API
-export([handle_action/2, push_event/2, sync_push_event/2,
         register_operator/1, register_operator/2]).

%% Internal functions, exported for eUnit, do not use!
-export([
         register/1,
         login/1,
         system_stats/1
        ]).

-include_lib("datatypes/include/push_receiver.hrl").
-include_lib("datatypes/include/push_event.hrl").
-include_lib("datatypes/include/user.hrl").
-include_lib("datatypes/include/game.hrl").

%% ------------------------------------------------------------------
%% Internal macros
%% ------------------------------------------------------------------
-define(WORKER, controller_app_worker).
-define(SELECT_WORKER, service_worker:select_pid(?WORKER)).
-define(CAST_WORKER(Cmd), gen_server:cast(?SELECT_WORKER, Cmd)).
-define(CALL_WORKER(Cmd), try gen_server:call(
                                service_worker:select_pid(?WORKER), Cmd)
                          catch
                              exit:{timeout, _} -> {error, timeout}
                          end).

%% ------------------------------------------------------------------
%% External API Function Definitions
%% ------------------------------------------------------------------
%%-------------------------------------------------------------------
%% @doc
%% Main controller function. Expects a command from the frontend,
%% a callback function, and its arguments. The callback is called
%% with the results of the given command. The callback function
%% must be of arity 3:
%%
%% CallbackFun(Args, {Type::command(), Result::result()},
%%                    ResultData::any()) -> ok.
%%
%% result() :: success | parse_error | invalid_data | invalid_session
%%             | access_denied | error.
%%
%% Standard return (error) values for invalid_data.
%% register ->          [nick_already_exists]
%% login ->             [nick_not_unique,
%%                       invalid_login_data,
%%                       simultaneous_login]
%% get_session_user ->  []
%% update_user ->       [does_not_exist]
%% create_game ->       []
%% get_game ->          [game_does_not_exist]
%% reconfig_game ->     [game_does_not_exist,
%%                       game_started_already,
%%                       not_game_creator]
%% game_order ->         [game_id_not_exist,
%%                       user_not_playing_this_game,
%%                       game_not_waiting]
%% join_game ->         [country_not_available,
%%                       user_already_joined]
%% game_overview ->     [user_not_playing_this_game]
%% logout ->            []
%% user_msg ->          [send_msg_to_yourself,
%%                       nick_not_unique,
%%                       black_listed,
%%                       invalid_nick]
%% games_current ->     []
%% game_search ->       []
%% game_msg ->          [not_allowed_send_msg,
%%                       game_does_not_exist,
%%                       game_phase_not_ongoing]
%% get_db_stats ->      [get_stats_body_fail,
%%                       get_stats_timeout,
%%                       get_stats_tcp_error,
%%                       get_stats_start_socket_fail,
%%                       not_operator]
%% power_msg ->         [game_does_not_exist,
%%                       game_phase_not_ongoing]
%% assign_moderator ->  [user_not_found]
%% get_system_status -> []
%% stop_game ->         []
%% get_games_ongoing -> []
%% get_presence ->      [user_not_found]
%% send_report ->       []
%% get_reports ->       []
%% mark_report_as_done -> [notfound]
%% set_push_receiver -> []
%% blacklist ->         [user_not_found]
%% whitelist ->         [user_not_found]
%%
%% @end
%%
%% Note: Whenever a new command is added to the controller, we need to update
%% the ACLs (tt_acl:moderator_cmd() and tt_acl:user_cmd)
%%-------------------------------------------------------------------
-type command() :: register |
             login |
             get_session_user |
             update_user |
             create_game |
             get_game |
             reconfig_game |
             game_order |
             join_game |
             game_overview |
             games_current |
             user_msg |
             game_msg |
             assign_moderator |
             power_msg |
             stop_game |
             get_presence |
             send_report |
             get_reports |
             mark_report_as_done |
             set_push_receiver |
             blacklist |
             whitelist |
             unknown_command.
-spec handle_action(ParsedData::{command(), {ok, any()}} |
                        {command(), {ok, SessionId::string()}} |
                        {command(), {ok, SessionId::string(), any()}} |
                        {command(), {error, any()}} |
                        {command(), Error::string()} |
                        string() |
                        unknown_command,
                    {CallbackFun::fun(), Args::[any()]}) -> ok.

handle_action({Command, {ok, Data}}, {CallbackFun, Args})
  when Command == register;
       Command == login ->
    case controller:Command(Data) of
        {error, Error} ->
            CallbackFun(Args, {Command, invalid_data}, Error);
        {ok, Result} ->
            CallbackFun(Args, {Command, success}, Result)
    end;
handle_action({Command, {ok, SessionId}}, {CallbackFun, Args})
  when Command == get_system_status ->
    case session:alive(SessionId) of
        false ->
            CallbackFun(Args, {Command, invalid_session}, SessionId);
        true->
            {ok, #user{role = Role}} = session:get_session_user(SessionId, user),
            case tt_acl:has_access(Command, Role) of
                true ->
                    {ok, Result} = system_stats(string),
                    CallbackFun(Args, {Command, success}, Result);
                false ->
                    CallbackFun(Args, {Command, access_denied}, Role)
            end
    end;
handle_action({Command, {ok, SessionId, Data}}, {CallbackFun, Args})
  when Command == update_user;
       Command == get_session_user;
       Command == create_game;
       Command == get_game;
       Command == reconfig_game;
       Command == game_overview;
       Command == join_game;
       Command == game_order;
       Command == logout;
       Command == user_msg;
       Command == games_current;
       Command == game_search;
       Command == get_db_stats;
       Command == game_msg;
       Command == assign_moderator;
       Command == power_msg;
       Command == stop_game;
       Command == get_games_ongoing;
       Command == get_presence;
       Command == send_report;
       Command == get_reports;
       Command == operator_get_game_msg;
       Command == operator_game_overview;
       Command == mark_report_as_done;
       Command == blacklist;
       Command == whitelist;
       Command == set_push_receiver ->
    case session:alive(SessionId) of
        false ->
            CallbackFun(Args, {Command, invalid_session}, SessionId);
        true->
            {ok, #user{role = Role}} = session:get_session_user(SessionId, user),
            case tt_acl:has_access(Command, Role, Data) of
                false ->
                    CallbackFun(Args, {Command, access_denied}, Role);
                true ->
                    case session:Command(SessionId, Data) of
                        {error, Error} ->
                            CallbackFun(Args, {Command, invalid_data}, Error);
                        {ok, Result} ->
                            CallbackFun(Args, {Command, success}, Result)
                    end
            end
    end;
handle_action({Command, Error}, {CallbackFun, Args}) ->
    CallbackFun(Args, {Command, parse_error}, Error);
handle_action(unknown_command, {CallbackFun, Args}) ->
    CallbackFun(Args, unknown_command, []);
handle_action(Cmd, {CallbackFun, Args}) ->
    CallbackFun(Args, unknown_command, Cmd).


%%-------------------------------------------------------------------
%% @doc
%% Pushes an event to the user with given id, if online.
%% @end
%%-------------------------------------------------------------------
-spec push_event(UserId::integer(), #push_event{}) -> ok.
push_event(UserId, Event = #push_event{}) ->
    ?CAST_WORKER({push_event, {UserId, Event}}).


%%-------------------------------------------------------------------
%% @doc
%% Pushes an event to the user with given id, if online, synchronously.
%% @end
%%-------------------------------------------------------------------
-spec sync_push_event(UserId::integer(), #push_event{}) -> ok.
sync_push_event(UserId, Event = #push_event{}) ->
    ?CALL_WORKER({push_event, {UserId, Event}}).


%%-------------------------------------------------------------------
%% @deprecated only for eunit
%% @doc register/1
%%
%% API for creation of a user
%% @end
%%-------------------------------------------------------------------
-spec register(#user{}) ->
          {ok, #user{}} |
          {error, nick_already_exists} |
          {{error, any()}}.
register(User) ->
    ?CALL_WORKER({register, User}).

%%-------------------------------------------------------------------
%%  @doc
%%    this function is used to register an operator
%%  @end
%%-------------------------------------------------------------------
-spec register_operator(#user{}) ->
          {ok, #user{}} |
          {error, nick_already_exists} |
          {{error, any()}}.
register_operator(User=#user{}) ->
    ?CALL_WORKER({register, User#user{role = operator}}).

%%-------------------------------------------------------------------
%%  @doc
%%    this function is used to register an operator to make register_operator
%%    easer in backend. It only gets nick and password and fill the other value
%%    and register an operator.
%%  @end
%%-------------------------------------------------------------------
-spec register_operator(string(), string()) ->
          {ok, #user{}} |
          {error, nick_already_exists} |
          {{error, any()}}.
register_operator(Nick, Password) ->
    User= #user{nick = Nick,
                email = "oprator@tt.com",
                password = Password,
                name = "Operator of the system",
                channel = web,
                last_login = never,
                last_ip = {127, 0, 0, 0}},
    register_operator(User).

%%-------------------------------------------------------------------
%% @deprecated only for eunit
%% @doc login/2
%%
%% API for logging in a user
%%
%% @end
%%-------------------------------------------------------------------
-spec login({#user{}, #push_receiver{}}) ->
          {ok, SessionId::string()} | {error, nick_not_unique} |
          {error, invalid_login_data} | {error, simultaneous_login}.
login(Data = {#user{}, #push_receiver{}}) ->
    ?CALL_WORKER({login, Data}).

%%-------------------------------------------------------------------
%% @doc system_stats
%%
%% API for getting system statistics
%%
%% @end
%%-------------------------------------------------------------------
-spec system_stats(OutputType::atom()) -> any() | {ok, string()}.
system_stats(OutputType) ->
    ?CALL_WORKER({system_stats, OutputType}).
