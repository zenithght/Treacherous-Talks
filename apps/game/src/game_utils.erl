%%%-------------------------------------------------------------------
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
%%%
%%% @doc Provides common utility functions for the game application
%%% @end
%%%
%%% @since : 15 Nov 2011 by Bermuda Triangle
%%% @end
%%%-------------------------------------------------------------------
-module(game_utils).

-include_lib ("datatypes/include/game.hrl").
-include_lib ("datatypes/include/message.hrl").
-include_lib ("datatypes/include/user.hrl").
-include_lib ("datatypes/include/push_event.hrl").
-include_lib ("datatypes/include/bucket.hrl").
-include_lib ("eunit/include/eunit.hrl").

-export([delete_map/1,
         get_all_orders/1,
         get_current_game/1,
         get_db_obj/3,
         get_default_map/0,
         get_game_current_key/1,
         get_game_msg_tree/1,
         get_game_order/1,
         get_game_player/1,
         get_game_state/1,
         get_keyprefix/1,
         get_keys/2,
         is_power_user/1,
         to_mapterm/1,
         to_rule_map/1,
         translate_game_order/3,
         update_db_obj/3,
         update_game/2,
         userlist/1
        ]).

-define(COUNTRIES, ["england", "germany", "france", "austria", "italy",
                    "russia", "turkey"]).

%%-------------------------------------------------------------------
%% @doc
%% Updates a game with the given ID with the given game record in the database.
%% Only if game in not waiting, use this function. Otherwise use reconfig_game
%%  to update game record.
%% @spec
%% update_game(ID :: integer(), Game :: #game{}) ->
%%     {ok, ID} | Error
%% @end
%%-------------------------------------------------------------------
update_game(ID, #game{} = Game) ->
    BinID = db:int_to_bin(ID),
    % Store Game record as proplist for search
    GamePropList = data_format:rec_to_plist(Game),
    DBGameObj=db_obj:create(?B_GAME, BinID, GamePropList),
    GamePutResult = db:put(DBGameObj, [{w,1}]),
    case GamePutResult of
        {error, _} = Error ->
            Error;
        _ ->
            {ok, ID}
    end.

%% ------------------------------------------------------------------
%% @doc creates a game_players record from the given game record
%% @spec
%%        get_game_player(#game{}) ->
%%               {ok, GamePlayer :: #game_player{}} | Error
%% @end
%% ------------------------------------------------------------------
get_game_player(Game= #game{})->
    Countries =[#game.england, #game.germany, #game.france, #game.austria,
                 #game.italy, #game.russia, #game.turkey],
    Fields = record_info(fields, game),
    PlayersInfo =fun(Country, ACC) ->
                         case element(Country, Game) of
                             undefined ->
                                 ACC;
                             UserId ->
                                 [#game_user{id = UserId,
                                             country = lists:nth(Country-1, Fields)}|ACC]
                         end
                 end,
    Players= lists:foldl(PlayersInfo, [], Countries),
    {ok, #game_player{id=Game#game.id, players=Players}}.

%% ------------------------------------------------------------------
%% @doc Builds a keyprefix, based on the current game
%% example output: "123451-1903-fall-order_phase"
%% @spec
%% get_keyprefix({id, ID :: integer()}
%%              | {game_current, Current :: #game_current{}}) ->
%%    KeyPrefix :: string() | {error, notfound}
%% @end
%% ------------------------------------------------------------------
get_keyprefix({id, ID}) ->
    case get_current_game(ID) of
        {ok, Current} ->
            get_keyprefix({game_current, Current});
        {error, notfound} ->
            % This case occurs when the game is in the wait state
            integer_to_list(ID) ++ "-1901-spring-order_phase"
    end;
get_keyprefix({game_current, Current}) ->
    {Year, Season} = Current#game_current.year_season,
    Key = integer_to_list(Current#game_current.id) ++ "-"
        ++ integer_to_list(Year) ++ "-"
        ++ atom_to_list(Season) ++ "-"
        ++ atom_to_list(Current#game_current.current_phase),
    Key.

%% ------------------------------------------------------------------
%% @doc Returns the country atom which a user is playing in a game
%% @spec
%%        get_current_game(ID :: integer()) ->
%%               {ok, CurrentGame :: #game_current{}} | Error
%% @end
%% ------------------------------------------------------------------
get_current_game(ID) ->
    get_db_obj(?B_GAME_CURRENT, get_game_current_key(ID), [{r,1}]).


%% ------------------------------------------------------------------
%% @doc Returns the current game key
%% @spec
%%        get_game_current_key(ID :: integer()) -> binary()
%% @end
%% ------------------------------------------------------------------
get_game_current_key(ID) ->
    list_to_binary(integer_to_list(ID) ++ "-" ++ "current").


%% ------------------------------------------------------------------
%% @doc Returns the game state of the game with id ID
%% @spec
%% get_game_state(GameID :: integer()) ->
%%     {ok, GameState :: #game_state{}} | Error
%% @end
%% ------------------------------------------------------------------
get_game_state(ID)->
    Key = get_keyprefix({id, ID}),
    get_db_obj(?B_GAME_STATE, Key, [{r,1}]).


%% ------------------------------------------------------------------
%% @doc
%% Gets all orders in the current season for a given game ID.
%% @spec
%% get_all_orders(ID :: integer()) ->
%%     OrderList :: list(tuple())
%% @end
%% ------------------------------------------------------------------
get_all_orders(ID) ->
    Key = game_utils:get_keyprefix({id, ID}),
    Keys = lists:map(fun(Country) ->
                             list_to_binary(Key ++ "-" ++ Country)
                     end, ?COUNTRIES),
    case db:get_values(?B_GAME_ORDER, Keys) of
        {ok, Orders} ->
            lists:flatten(lists:map(fun(Order) ->
                                            Order#game_order.order_list
                                    end, Orders));
        Error ->
            erlang:error(Error)
    end.

%% ------------------------------------------------------------------
%% @doc Gets the game orders for a given key
%% Key: "3457892458-1901-fall-order_phase-england"
%% @spec
%% get_game_order(ID) -> list(tuple())
%% @end
%% ------------------------------------------------------------------
get_game_order(ID)->
    case game_utils:get_db_obj(?B_GAME_ORDER, ID, [{r,1}]) of
        {ok, Orders} ->
            Orders#game_order.order_list;
        _Error -> []
    end.

%% ------------------------------------------------------------------
%% @doc
%% Creates pairs of users and their usernames
%% @spec
%% userlist(#game{}) ->
%%     CountryUserList :: list(tuple())
%% @end
%% ------------------------------------------------------------------
userlist(Game) ->
    {ok, GamePlayer} = get_game_player(Game),
    CreatePairs =
        fun(Player, Acc) ->
                case user_management:get(Player#game_user.id) of
                    #user{role= disabled} ->
                        [{Player#game_user.country,
                          "black listed user"}] ++ Acc;
                    User = #user{} ->
                        [{Player#game_user.country,
                          User#user.nick}] ++ Acc;
                    _Other ->
                        [{Player#game_user.country,
                          integer_to_list(Player#game_user.id)}] ++ Acc
                end
        end,
    lists:foldl(CreatePairs, [], GamePlayer#game_player.players).

%% ------------------------------------------------------------------
%% @doc
%% Creates a standard map
%% @spec
%% get_default_map() -> Map :: term()
%% @end
%% ------------------------------------------------------------------
get_default_map() ->
    map_data:create (standard_game).

%% ------------------------------------------------------------------
%% @doc
%% Deletes a map
%% @spec
%% delete_map(Map :: digraph()) -> ok
%% @end
%% ------------------------------------------------------------------
delete_map(Map) ->
    map_data:delete (Map).

%% ------------------------------------------------------------------
%% @doc
%% Converts a handle of a digraph map into interpretable erlang terms
%% @end
%% ------------------------------------------------------------------
to_mapterm(RuleHandle) ->
    digraph_io:to_erlang_term(RuleHandle).

%% ------------------------------------------------------------------
%% @doc
%% Converts a map in erlang terms into a map handle, which can be used
%% by the rule engine
%% @end
%% ------------------------------------------------------------------
to_rule_map(MapTerm) ->
    digraph_io:from_erlang_term(MapTerm).

%% ------------------------------------------------------------------
%% @doc
%% Gets keys, Field is a field in a record and Val its value.
%% @spec
%% get_keys(Field :: any(), Val :: any()) ->
%%    {ok, Keys :: list()} | {error, Error}
%% @end
%% ------------------------------------------------------------------
get_keys(Field, Val) ->
    {ok, Query} = db_utils:get_search_term(Field, Val, ?GAME_REC_NAME),
    case db_utils:do_search(?B_GAME, Query) of
        {ok, []} ->
            {ok, []};
        {ok, List} ->
            {ok, List};
        Other ->
            {error, Other}
    end.

%% ------------------------------------------------------------------
%% @doc Gets and object from the database, according to the given
%% bucket and key.
%% @spec
%%        get_db_obj(Bucket :: binary(),
%%                   Key :: any(),
%%                   Options :: [any()]) ->
%%               {ok, DBObj :: any()} | Other
%% @end
%% ------------------------------------------------------------------
get_db_obj(Bucket, Key, Options) ->
    if
        is_binary(Key) -> BinKey = Key;
        is_integer(Key) -> BinKey = db:int_to_bin(Key);
        is_list(Key) -> BinKey = list_to_binary(Key);
        is_atom(Key) -> BinKey = list_to_binary(atom_to_list(Key));
        true -> BinKey = Key % don't know what else it could be!
    end,
    DBReply = db:get(Bucket, BinKey, Options),
    case DBReply of
        {ok, DBObj} ->
            {ok, db_obj:get_value(DBObj)};
        Other ->
            Other
    end.


%% ------------------------------------------------------------------
%% @doc Updates a database object with a new value
%% @spec
%%        update_db_obj(OldObject :: any(),
%%                      NewValue :: any(),
%%                      Options :: [any()]) ->
%%               {ok, NewValue}
%% @end
%% ------------------------------------------------------------------
update_db_obj(OldObj, NewVal, Options) ->
    DBObj = db_obj:set_value(OldObj, NewVal),
    db:put(DBObj, Options),
    NewVal.


%%------------------------------------------------------------------------------
%% @doc
%%   to translate the pasred user entry for order to agree with our rule engine
%% @end
%% @spec
%% translate_game_order(GameId :: integer(),
%%                      GameOrderList :: list(tuple()),
%%                      Country :: country()) -> list(tuple())
%% @end
%%------------------------------------------------------------------------------
translate_game_order(GameId, GameOrderList,Country) ->
    case get_game_map(GameId) of
        {ok, Map} ->
            RuleMap = to_rule_map(Map),
            Result = translate_game_order(GameId, GameOrderList,Country, [],
                                          RuleMap),
            delete_map(RuleMap),
            Result;
        Error ->
            Error
    end.

translate_game_order(_GameId, [],_Country, Acc, _Map) ->
    Acc;
translate_game_order(GameId, [H|Rest],Country, Acc, Map) ->
    Type=element(1,H),
    TranslatedOrder =
        case Type of
            move ->
                {_, Unit, From, To, _} = H,
                {move, {Unit, Country}, From, To};
            hold ->
                {_, Unit, Wh} = H,
                {hold, {Unit, Country}, Wh};
            support_move ->
                {_, SupUnit, SupportWh, _, From, To, _} = H,
                case map:get_units(Map, From) of
                    [] ->
                        [];
                    Result when length(Result) > 1 ->
                        [];
                    [{Unit, UConutry}] ->
                        {support, {SupUnit, Country}, SupportWh,
                         {move, {Unit, UConutry}, From, To}}
                end;
            support_hold ->
                {_, SupUnit, SupportWh, _, Wh} = H,
                case map:get_units(Map, Wh) of
                    [] ->
                        [];
                    Result when length(Result) > 1 ->
                        [];
                    [{Unit, UConutry}] ->
                        {support, {SupUnit, Country}, SupportWh,
                         {hold, {Unit, UConutry}, Wh}}
                end;
            convoy ->
                {_, Fleet, Wh, _, From, To} = H,
                case map:get_units(Map, From) of
                    [] ->
                        [];
                    Result when length(Result) > 1 ->
                        [];
                    [{Army, UConutry}] ->
                        {convoy, {Fleet, Country}, Wh,
                         {Army, UConutry}, From, To}
                end;
            build ->
                {_, Unit, Wh, _} = H,
                {build, {Unit, Country}, Wh};
            disband ->
                {_, Unit, Wh} = H,
                {disband, {Unit, Country}, Wh}
        end,
    case TranslatedOrder of
        [] ->
            translate_game_order(GameId, Rest,Country, Acc, Map);
        _->
            translate_game_order(GameId, Rest,Country, [TranslatedOrder|Acc], Map)
    end.

%% ------------------------------------------------------------------
%% @doc
%% Checks if a user role is a power user (moderator or operator)
%% @spec
%% is_power_user(Role :: atom()) -> boolean()
%% @end
%% ------------------------------------------------------------------
is_power_user(Role) when Role == moderator ; Role == operator ->
    true;
is_power_user(_Role) ->
    false.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
%% ------------------------------------------------------------------
%% @doc
%% Get the game map from game state of current phase
%%
%% GameID :: integer()
%% Output-> {ok, Map::term()}
%% @end
%% ------------------------------------------------------------------
get_game_map(GameID) ->
    case  get_db_obj(?B_GAME_STATE, get_keyprefix({id, GameID}), [{r,1}]) of
        {ok, State} ->
            {ok, State#game_state.map};
        Error ->
            Error
    end.

%%-------------------------------------------------------------------
%% @doc
%% Get a hierachical tree,
%% so that operator UI can use this tree to render in-game message navigator
%%
%% Output Example:
%% {ok, {year, [{1901,
%%          [{spring_order_phase,
%%            [england,germany]},
%%           {spring-retreat_phase,
%%            [english,germany,austria]}
%%          ]
%%         },
%%         {1902,
%%          [{spring_order_phase,
%%            [english,germany]}]}]}}
%% @end
%%-------------------------------------------------------------------
get_game_msg_tree(GameId) ->
    case message:get_all_game_msg(GameId) of
        {ok, GMsgList} ->
            Fun = fun(X, Y)->
                     X#game_message.date_created < Y#game_message.date_created
                  end,
            SortedList = lists:usort(Fun, GMsgList),
            {ok, game_msg_tree(SortedList)};
        Error -> Error
    end.


%%-------------------------------------------------------------------
%% @doc
%% Helper function for converting game_message history to a hierachical tree,
%% so that operator UI can use this tree to render in-game message navigator
%%
%% Output Example:
%% {year, [{1901,
%%          [{spring_order_phase,
%%            [england,germany]},
%%           {spring-retreat_phase,
%%            [english,germany,austria]}
%%          ]
%%         },
%%         {1902,
%%          [{spring_order_phase,
%%            [english,germany]}]}]}
%% @end
%%-------------------------------------------------------------------
-spec game_msg_tree([#game_message{}]) -> [term()].
game_msg_tree(GMsgList) ->
    lists:foldl(fun(#game_message{year=Year, season=Season,
                                  phase=Phase, sender_country=Country},
                    Acc) ->
                        YList = case lists:keyfind(Year, 1, Acc) of
                                    false -> [];
                                    {Year, Val} -> Val
                                end,
                        SList = case lists:keyfind({Season, Phase}, 1,
                                                   YList) of
                                    false -> [];
                                    {_, SVal} -> SVal
                                end,
                        NewSList = case lists:member(Country, SList) of
                                       true -> SList;
                                       false -> [Country|SList]
                                   end,
                        NewYList = lists:keystore(
                                     {Season, Phase}, 1, YList,
                                     {{Season, Phase}, NewSList}),
                        lists:keystore(Year, 1, Acc, {Year, NewYList})
                end, [], GMsgList).
