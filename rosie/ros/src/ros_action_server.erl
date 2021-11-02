-module(ros_action_server).

-export([start_link/3, cancel_goal/2, publish_feedback/2, publish_result/3]).

-behaviour(gen_service_listener).

-export([on_client_request/2]).

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2]).

-include_lib("dds/include/dds_types.hrl").
-include_lib("action_msgs/src/_rosie/action_msgs_goal_status_array_msg.hrl").
-include_lib("action_msgs/src/_rosie/action_msgs_cancel_goal_srv.hrl").

-record(goal, {uuid, time = #builtin_interfaces_time{}, status = ?STATUS_ACCEPTED}).
-record(state,
        {node,
         % module holding interface infos
         action_interface,
         % ros services to serve this action
         request_goal_service,
         cancel_goal_service,
         get_result_service,
         % ros publishers to topics for this action
         feed_publisher,
         status_publisher,
         % user callbacks
         callback_handler,
         goals_accepted = #{},
         goals_with_requested_results = [],
         cached_goal_results = []}).

start_link(Node, Action, {CallbackModule, Pid}) ->
    gen_server:start_link(?MODULE,
                          #state{node = Node,
                                 action_interface = Action,
                                 callback_handler = {CallbackModule, Pid}},
                          []).

% is_goal_cancel_requested(Name, Msg) ->
%         [Pid|_] = pg:get_members(Name),
%         gen_server:call(Pid, {is_goal_cancel_requested, Msg}).

cancel_goal(Name, Msg) ->
    [Pid | _] = pg:get_members(Name),
    gen_server:cast(Pid, {cancel_goal, Msg}).

publish_feedback(Name, Msg) ->
    [Pid | _] = pg:get_members(Name),
    gen_server:call(Pid, {publish_feedback, Msg}).

publish_result(Name, GoalID, Result) ->
    [Pid | _] = pg:get_members(Name),
    gen_server:call(Pid, {publish_result, GoalID, Result}).

on_client_request(Name, Request) ->
    [Pid | _] = pg:get_members(Name),
    gen_server:call(Pid, {on_client_request, Request}).

%callbacks
init(#state{node = Node,
            action_interface = Action,
            callback_handler = CallbackHandler} =
         S) ->
    ServerName = {?MODULE, Node, Action},
    pg:join(ServerName, self()),

    %customized by the user
    RequestGoalService =
        ros_node:create_service(Node, Action:get_goal_srv_module(), {?MODULE, ServerName}),
    GetResultService =
        ros_node:create_service(Node, Action:get_result_srv_module(), {?MODULE, ServerName}),
    FeedbackPub =
        ros_node:create_publisher(Node,
                                  Action:get_feedback_msg_module(),
                                  Action:get_action_name() ++ "/_action/feedback"),

    %standard but names must be specialized for this action instance
    CancelGoalService =
        ros_node:create_service(Node,
                                {action_msgs_cancel_goal_srv, Action:get_action_name() ++ "/_action/"},
                                {?MODULE, ServerName}),
    % status topic cannot be left with volatile durability
    StatusTopicsProfile = #qos_profile{durability = ?TRANSIENT_LOCAL_DURABILITY_QOS},
    StatusPub =
        ros_node:create_publisher(Node,
                                action_msgs_goal_status_array_msg,
                                  Action:get_action_name() ++ "/_action/status",
                                  StatusTopicsProfile),

    {ok,
     S#state{request_goal_service = RequestGoalService,
             cancel_goal_service = CancelGoalService,
             get_result_service = GetResultService,
             % ros subscription to remote topics for this action
             feed_publisher = FeedbackPub,
             status_publisher = StatusPub}}.

handle_call({publish_feedback, Feed},
            _,
            #state{action_interface = AI, feed_publisher = FeedbackPub} = S) ->
    ros_publisher:publish(FeedbackPub, Feed),
    {reply, ok, S};
handle_call({publish_result, GoalID, Result},
            _,
            #state{action_interface = AI,
                   goals_with_requested_results = GRR,
                   get_result_service = GetResultService,
                   cached_goal_results = Cached} =
                S) ->
    case [{ClientID, RN} || {ClientID, RN, ID, _} <- GRR, ID == GoalID] of
        [] ->
            {reply, ok, S#state{cached_goal_results = [Result | Cached]}};
        RRL ->
            [ros_service:send_response(GetResultService, {ClientID, RN, Result})
             || {ClientID, RN} <- RRL],
            {reply, ok, publish_goal_status_update(mark_goal_as(GoalID, ?STATUS_SUCCEEDED, S))}
    end;
handle_call({on_client_request, {{ClientId, RequestNumber}, Msg}},
            _,
            #state{action_interface = AI, callback_handler = {M, Pid}} = S) ->
    case AI:identify_msg(Msg) of
        send_goal_rq ->
            h_manage_goal_request(Msg, S);
        get_result_rq ->
            h_manage_result_request(ClientId, RequestNumber, Msg, S);
        cancel_goal_rq ->
            h_manage_cancel_request(Msg, S);
        _ ->
            io:format("[ROS_ACTION_SERVER]: BAD MSG RECEIVED FROM CLIENT\n"),
            {reply, error, S}
    end.

handle_cast({cancel_goal, UUID},
            #state{action_interface = AI, cancel_goal_service = CancelGoalService} = S) ->
    G_INFO = #action_msgs_goal_info{goal_id = UUID},
    NewState = clear_cache_for_goal(UUID, mark_goal_as(UUID, ?STATUS_CANCELED, S)),
    {noreply, publish_goal_status_update(NewState)};
handle_cast(_, S) ->
    {noreply, S}.

publish_goal_status_update(#state{action_interface = AI,
                                  status_publisher = S_PUB,
                                  goals_accepted = GA} =
                               S) ->
    LIST =
        [#action_msgs_goal_status{goal_info = #action_msgs_goal_info{goal_id = UUID, stamp = T},
                                  status = STATUS}
         || #goal{uuid = UUID,
                  time = T,
                  status = STATUS}
                <- maps:values(GA)],
    ros_publisher:publish(S_PUB, #action_msgs_goal_status_array{status_list = LIST}),
    S.

h_manage_goal_request(Msg,
                      #state{action_interface = AI,
                             callback_handler = {M, Pid},
                             goals_accepted = GA} =
                          S) ->
    Reply = M:on_new_goal_request(Pid, Msg),
    case AI:get_responce_code(Reply) of
        0 ->
            {reply, Reply, S};
        1 ->
            M:on_execute_goal(Pid, Msg),
            NewState =
                S#state{goals_accepted =
                            GA#{AI:get_goal_id(Msg) =>
                                    #goal{uuid = AI:get_goal_id(Msg),
                                          time = #builtin_interfaces_time{},
                                          status = ?STATUS_EXECUTING}}},
            {reply, Reply, publish_goal_status_update(NewState)}
    end.

clear_cache_for_goal(UUID,
                     #state{action_interface = AI, cached_goal_results = CachedResults} = S) ->
    S#state{cached_goal_results = [R || R <- CachedResults, AI:get_goal_id(R) /= UUID]}.

mark_goal_as(UUID, NewGoalState, #state{goals_accepted = GA} = S) ->
    case maps:get(UUID, GA, not_found) of
        not_found ->
            S;
        G ->
            S#state{goals_accepted = GA#{UUID => G#goal{status = NewGoalState}}}
    end.

h_manage_result_request(ClientID,
                        RequestNumber,
                        Msg,
                        #state{action_interface = AI,
                               callback_handler = {M, Pid},
                               goals_accepted = GA,
                               goals_with_requested_results = GRQ,
                               cached_goal_results = CachedResults} =
                            S) ->
    case maps:get(
             AI:get_goal_id(Msg), GA, not_found)
    of
        not_found ->
            io:format("[ROS_ACTION_SERVER]: result requested but goal not found.\n"),
            {reply, ros_service_noreply, S};
        #goal{uuid = ID} ->
            case [R || R <- CachedResults, ID == AI:get_goal_id(Msg)] of
                [] ->
                    {reply,
                     ros_service_noreply,
                     S#state{goals_with_requested_results =
                                 [{ClientID, RequestNumber, AI:get_goal_id(Msg), put_time_here}
                                  | GRQ]}};
                [R | _] ->
                    NewS = mark_goal_as(AI:get_goal_id(R), ?STATUS_SUCCEEDED, S),
                    {reply, R, publish_goal_status_update(NewS)}
            end
    end.

% if uuid is 0 or time is 0 i do not handle them for now
h_manage_cancel_request(#action_msgs_cancel_goal_rq{goal_info =
                                                        #action_msgs_goal_info{goal_id =
                                                                                   #unique_identifier_msgs_u_u_i_d{uuid
                                                                                                                       =
                                                                                                                       <<0:16/binary>>}}},
                        S) ->
    io:format("[ROS_ACTION_SERVER]: not implemented: management of multiple goals cancellation."),
    {reply, #action_msgs_cancel_goal_rp{return_code = ?ERROR_REJECTED}, S};
h_manage_cancel_request(#action_msgs_cancel_goal_rq{goal_info =
                                                        #action_msgs_goal_info{goal_id = UUID,
                                                                               stamp = T}} =
                            R,
                        #state{action_interface = AI,
                               goals_accepted = GA,
                               callback_handler = {M, Pid}} =
                            S) ->
    case maps:get(UUID, GA, not_found) of
        not_found ->
            {reply, #action_msgs_cancel_goal_rp{return_code = ?ERROR_UNKNOWN_GOAL_ID}, S};
        #goal{status = ?STATUS_CANCELED} ->
            {reply, #action_msgs_cancel_goal_rp{return_code = ?ERROR_GOAL_TERMINATED}, S};
        #goal{status = ?STATUS_SUCCEEDED} ->
            {reply, #action_msgs_cancel_goal_rp{return_code = ?ERROR_GOAL_TERMINATED}, S};
        _ ->
            case M:on_cancel_goal_request(Pid, R) of
                accept ->
                    G_INFO = #action_msgs_goal_info{goal_id = UUID},
                    M:on_cancel_goal(Pid, UUID),
                    {reply,
                     #action_msgs_cancel_goal_rp{return_code = ?ERROR_NONE,
                                                 goals_canceling = [G_INFO]},
                     publish_goal_status_update(mark_goal_as(UUID, ?STATUS_CANCELING, S))};
                reject ->
                    {reply, #action_msgs_cancel_goal_rp{return_code = ?ERROR_REJECTED}, S};
                _ ->
                    io:format("[ROS_ACTION_SERVER] bad cancel reply, defaulting to reject"),
                    {reply, #action_msgs_cancel_goal_rp{return_code = ?ERROR_REJECTED}, S}
            end
    end.
