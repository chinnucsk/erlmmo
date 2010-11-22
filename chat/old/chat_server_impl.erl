-module (chat_server_impl).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
%%%
% Chat_master:
% The chat_server is central router for chat messages. Through the public api sessions can join/part channels
% and direct messages to it, which are then rerouted to all joined sessions.
%%%
% Error Handling:
% There are two types or errors that can occur, that we handle:
%  illegal error: This error occures, when the user plays around with the api, which he is not
%                 supposed to do.
%                 These errors are logger to the 'error_logger' module. The user action is
%                 silently (for the user) ignored.
%  user error: When a user error occures, the user did something wrong / what we don't allow.
%              e.g. sending an empty chat message or joining a channel with illegal characters
%              When this happens, we send the user an error message from the list below.
%              The error codes shall be unique. The range for the chat_server is 20.000 - 29.999
%%
-define(ERROR_20001, {error, 20001, <<"Invalid channelname. Unable to join.">>}).
-define(ERROR_20002, {error, 20002, <<"You are already in this channel.">>}).
-define(ERROR_20003, {error, 20003, <<"Invalid chat message.">>}).
-define(ERROR_20004, {error, 20004, <<"This is a system channel. You cannot manually join/part it.">>}).
-define(ERROR_20005, {error, 20005, <<"You cannot connect while a consumer with the same ID is already connected."}).

-record(channel, {id, system = false, name, sessions=[]}).

-record(state, {callback, table, consumer_table}).

%% ------------------------------------------------------------------------------
%% Implementation Note:
% This master process stores its data in two tables:
% - Connected Consumers (Reference, Name)
% - Available Channels (Reference, JoinedConsumers)
-define(TABLE, chat_channels).
-define(CONSUMER_TABLE, chat_consumers).


init([]) ->
    ChannelTid =  ets:new(?TABLE,          [set, protected, {keypos,2}]),
    ConsumerTid = ets:new(?CONSUMER_TABLE, [set, protected]),
    
    State = #state{table=ChannelTid, consumer_table=ConsumerTid},
    {ok, State}.
    
handle_cast({connect, Reference, ClientName, ClientCallbackFun}, State = #state{consumer_table=CTid}) ->
    % Check if the user has already been connected
    case ets:lookup(CTid, Reference) of
        [] ->
            % ID is empty, save the connecting client
            ets:insert(CTid, {Reference, ClientName, ClientCallbackFun});
            
        [{Reference, OtherName, OtherCallbackFun}] ->
            % Notify the connecting client that he does not be connected
            ClientCallbackFun(?ERROR_20005)
    end,
    {noreply, State};
    
handle_cast({disconnect, ConsumerRef, _Reason}, State = #state{table=Tid, consumer_table=CTid}) ->
    ok = internal_kill(ConsumerRef, Tid),
    ets:delete(CTid, ConsumerRef),
    {noreply, State};
    
handle_cast({chat_join, Session, ChannelId}, State = #state{table=Tid}) ->
    {ChannelName, IsSystemChannel} = case is_atom(ChannelId) of
        true ->
            case ChannelId of
                channel_moderators -> {<<"Moderators">>, true};
                channel_admins -> {<<"Admins">>, true};
                channel_guild -> {<<"Guild">>, true};
                _ -> {<<"Local">>, true}
            end;
        _ -> {ChannelId, false}
    end,
    
    case validation:validate_chat_channel(ChannelName) of
        false ->
            Session:add_message(?ERROR_20001),
            {noreply, State};
        true -> 
            Channel = case ets:lookup(Tid, ChannelId) of
                [A] -> A;
                [] -> #channel{id=ChannelId, name=ChannelName, system=IsSystemChannel}
            end,
            OldSessions = Channel#channel.sessions,
            
            case lists:member(Session, OldSessions) of
                true ->
                    % Session is already in that channel
                    Session:add_message(?ERROR_20002),
                    ok;
                false ->
                    NewSessions = OldSessions ++ [Session],
                    NewChannel = Channel#channel{sessions=NewSessions},
                    ets:insert(Tid, NewChannel),
                    
                    OtherNames = lists:map(fun(X) -> X:get_name() end, NewSessions),
                    
                    % Send the joiner the list of names
                    Session:add_message({chat_join_self, ChannelName, OtherNames}),
                    
                    % Send all other, the join
                    lists:foreach(fun(X) -> X:add_message({chat_join, ChannelName, Session:get_name()}) end, OldSessions)
            end,
            {noreply, State}
    end;

handle_cast({chat_send, Session, ChannelId, Message}, State = #state{table=Tid}) ->
    case validation:validate_chat_message(Message) of
        true ->
            case ets:lookup(Tid, ChannelId) of
                [Channel] ->
                    case lists:member(Session, Channel#channel.sessions) of
                        true ->
                            lists:foreach(
                                fun(UserSession) ->
                                    UserSession:add_message({chat_send, Channel#channel.name, Session:get_name(), Message})
                                end,
                                Channel#channel.sessions
                            );
                        false ->
                            error_logger:error_msg("[CHAT] Session�~p sending message to channel '~s' in which he is no member: ~p~n", [Session, Channel#channel.name, Message])
                    end;
                [] ->
                    error_logger:error_msg("[CHAT] Session ~p sending message to non-existing channel ~p: ~p~n", [Session, ChannelId, Message])
            end;
        false ->
            Session:add_message(?ERROR_20003),
            ok
    end,
    {noreply, State};
    
handle_cast({chat_part, Session, ChannelId}, State = #state{table=Tid}) ->
    case ets:lookup(Tid, ChannelId) of
        [Channel] ->
            NewSessions = lists:filter(
                fun(UserSession) ->
                    not(UserSession =:= Session)
                end,
                Channel#channel.sessions
            ),
            case NewSessions of
                [] ->
                    ets:delete(Tid, ChannelId);
                NewSessions ->
                    ets:insert(Tid, Channel#channel{sessions=NewSessions})
            end,
            
            lists:foreach(fun(S) ->
                S:add_message({chat_part, Channel#channel.name, Session:get_name()}) end,
                NewSessions
            ),            
            Session:add_message({chat_part_self, Channel#channel.name});
        [] ->
            % We do not log this anymore, since on a logout, the zone might log the user out of the 'local' chan,
            % after the session has already been killed from the chat_master
            % error_logger:error_msg("[CHAT] Session ~p parting from a non-existing channel ~p", [Session, ChannelId]),
            ok
    end,
    {noreply, State}.
    

handle_call({chat_list, Session}, _From, State = #state{table=Tid}) ->
    Channels = ets:tab2list(Tid),
    ChannelList = lists:flatten(
        lists:map(fun(Channel) ->
                IsMember = lists:member(Session, Channel#channel.sessions),
                
                case IsMember of
                    false -> [];
                    true ->
                        case Channel#channel.system of
                            true -> [];
                            false -> Channel#channel.id
                        end
                end
            end,
            Channels
        )
    ),
    {reply, {ok, ChannelList}, State};
    
handle_call(channel_list, _From, State = #state{table=Tid}) ->
    Channels = ets:tab2list(Tid),
    ChannelNames = lists:map(fun(X) -> X#channel.name end, lists:filter(fun(X) -> not(X#channel.system) end, Channels)),
    {reply, {ok, ChannelNames}, State};
    
handle_call(_Message, _From, State) ->
    {noreply, State}.
    
handle_info(_Message, State) ->
    {noreply, State}.
    
terminate(_Reason, _State) ->
    ok.
    
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% -------------------
% internal helper functions:


%%%
% Deletes the given session from all channels.
% The appropriate chat_part message gets send, too.
internal_kill(Session, Tid) ->
    ets:safe_fixtable(Tid, true),
    Result = (catch internal_kill(Session, Tid, ets:first(Tid))),
    ets:safe_fixtable(Tid, false),
    Result.
    
internal_kill(_, _, '$end_of_table') -> ok;
internal_kill(Session, Tid, Element) ->
    [Channel] = ets:lookup(Tid, Element),
    
    OldSessions = Channel#channel.sessions,
    NewSessions = lists:filter(
        fun(X) ->
            not(X =:= Session)
        end,
        OldSessions
    ),
    
    lists:foreach(fun(S) -> S:add_message({chat_part, Channel#channel.name, Session:get_name()}) end, NewSessions),
    
    % overwrite the existing channel with the new one.
    case NewSessions of
        [] ->
            ets:delete(Tid, Element);
        NewSessions ->
            ets:insert(Tid, Channel#channel{sessions=NewSessions})
    end,
    
    Next = ets:next(Tid, Element),
    internal_kill(Session, Tid, Next).
    
    
%%
% Prints the status about the chat on the output.
internal_status(Tid) ->
    io:format("ID\tChannel\tSessions\tSystem"),
    internal_status(Tid, ets:first(Tid)),
    io:format("-- end of channel status --~n").
    
internal_status(_, '$end_of_table') -> ok;
internal_status(Tid, Key) ->
    [Channel] = ets:lookup(Tid, Key),
    io:format("~p\t~s\t~w\t~p~n", [Channel#channel.id, Channel#channel.name, length(Channel#channel.sessions), Channel#channel.system]),
    
    internal_status(Tid, ets:next(Tid, Key)).