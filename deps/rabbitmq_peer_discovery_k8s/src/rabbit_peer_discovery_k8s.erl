%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% https://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is AWeber Communications.
%% Copyright (c) 2015-2016 AWeber Communications
%% Copyright (c) 2016-2017 Pivotal Software, Inc. All rights reserved.
%%

-module(rabbit_peer_discovery_k8s).
-behaviour(rabbit_peer_discovery_backend).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbitmq_peer_discovery_common/include/rabbit_peer_discovery.hrl").
-include("rabbit_peer_discovery_k8s.hrl").

-export([init/0, list_nodes/0, supports_registration/0, register/0, unregister/0,
         post_registration/0, lock/1, unlock/1, randomized_startup_delay_range/0,
         send_event/3]).

-ifdef(TEST).
-compile(export_all).
-endif.

-define(CONFIG_MODULE, rabbit_peer_discovery_config).
-define(UTIL_MODULE,   rabbit_peer_discovery_util).
-define(HTTPC_MODULE,  rabbit_peer_discovery_httpc).

-define(BACKEND_CONFIG_KEY, peer_discovery_k8s).


%%
%% API
%%

init() ->
    rabbit_log:debug("Peer discovery Kubernetes: initialising..."),
    ok = application:ensure_started(inets),
    %% we cannot start this plugin yet since it depends on the rabbit app,
    %% which is in the process of being started by the time this function is called
    application:load(rabbitmq_peer_discovery_common),
    proc_lib:spawn(fun monitor_nodes/0),
    rabbit_peer_discovery_httpc:maybe_configure_proxy(),
    rabbit_peer_discovery_httpc:maybe_configure_inet6().

-spec list_nodes() -> {ok, {Nodes :: list(), NodeType :: rabbit_types:node_type()}}.

list_nodes() ->
    case make_request() of
	{ok, Response} ->
	    Addresses = extract_node_list(Response),
	    {ok, lists:map(fun node_name/1, Addresses)};
	{error, Reason} ->
	    rabbit_log:info(
	      "Failed to get nodes from k8s - ~s", [Reason]),
          send_event("Warning", "Failed",  
          io_lib:format("Failed to get nodes from k8s - ~s", [Reason])), 
  	    {error, Reason}
    end.

-spec supports_registration() -> boolean().

supports_registration() ->
    %% see rabbitmq-peer-discovery-aws#17,
    %%     rabbitmq-peer-discovery-k8s#23
    true.


-spec register() -> ok.
register() ->
    ok.

-spec unregister() -> ok.
unregister() ->
    ok.

-spec post_registration() -> ok | {error, Reason :: string()}.

post_registration() ->
    send_event("Normal", "Created",  io_lib:format("Node ~s is registered", [node()])), 
    ok.

-spec lock(Node :: atom()) -> not_supported.

lock(_Node) ->
    not_supported.

-spec unlock(Data :: term()) -> ok.

unlock(_Data) ->
    ok.

-spec randomized_startup_delay_range() -> {integer(), integer()}.

randomized_startup_delay_range() ->
    %% Pods in a stateful set are initialized one by one,
    %% so RSD is not really necessary for this plugin.
    %% See https://www.rabbitmq.com/cluster-formation.html#peer-discovery-k8s for details.
    {0, 2}.

%%
%% Implementation
%%

-spec get_config_key(Key :: atom(), Map :: #{atom() => peer_discovery_config_value()})
                    -> peer_discovery_config_value().

get_config_key(Key, Map) ->
    ?CONFIG_MODULE:get(Key, ?CONFIG_MAPPING, Map).

%% @doc Perform a HTTP GET request to K8s
%% @end
%%
-spec make_request() -> {ok, term()} | {error, term()}.
make_request() ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    {ok, Token} = file:read_file(get_config_key(k8s_token_path, M)),
    Token1 = binary:replace(Token, <<"\n">>, <<>>),
    ?HTTPC_MODULE:get(
      get_config_key(k8s_scheme, M),
      get_config_key(k8s_host, M),
      get_config_key(k8s_port, M),
      base_path(endpoints,get_config_key(k8s_service_name, M)),
      [],
      [{"Authorization", "Bearer " ++ binary_to_list(Token1)}],
      [{ssl, [{cacertfile, get_config_key(k8s_cert_path, M)}]}]).

%% @spec node_name(k8s_endpoint) -> list()  
%% @doc Return a full rabbit node name, appending hostname suffix
%% @end
%%
node_name(Address) ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    ?UTIL_MODULE:node_name(
       ?UTIL_MODULE:as_string(Address) ++ get_config_key(k8s_hostname_suffix, M)).


%% @spec maybe_ready_address(k8s_subsets()) -> list()
%% @doc Return a list of ready nodes
%% SubSet can contain also "notReadyAddresses"  
%% @end
%%
maybe_ready_address(Subset) ->
    case maps:get(<<"notReadyAddresses">>, Subset, undefined) of
      undefined -> ok;
      NotReadyAddresses ->
            Formatted = string:join([binary_to_list(get_address(X))
                                     || X <- NotReadyAddresses], ", "),
            rabbit_log:info("k8s endpoint listing returned nodes not yet ready: ~s",
                            [Formatted])
    end,
    maps:get(<<"addresses">>, Subset, []).

%% @doc Return a list of nodes
%%    see https://kubernetes.io/docs/api-reference/v1/definitions/#_v1_endpoints
%% @end
%%
-spec extract_node_list(term()) -> [binary()].
extract_node_list(Response) ->
    IpLists = [[get_address(Address)
		|| Address <- maybe_ready_address(Subset)]
	       || Subset <- maps:get(<<"subsets">>, Response, [])],
    sets:to_list(sets:union(lists:map(fun sets:from_list/1, IpLists))).


%% @doc Return a list of path segments that are the base path for k8s key actions
%% @end
%%
-spec base_path(events | endpoints, term()) -> [?HTTPC_MODULE:path_component()].
base_path(Type, Args) ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    {ok, NameSpace} = file:read_file(
			get_config_key(k8s_namespace_path, M)),
    NameSpace1 = binary:replace(NameSpace, <<"\n">>, <<>>),
    [api, v1, namespaces, NameSpace1, Type,
     Args].

%% get_config_key(k8s_service_name, M)    

get_address(Address) ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    maps:get(list_to_binary(get_config_key(k8s_address_type, M)), Address).


%% @doc Perform a HTTP POST request to K8s to send and event
%% @end
%%
-spec send_event(term(),term(), term()) -> {ok, term()} | {error, term()}.
send_event(Type, Reason, Message) ->
    M = ?CONFIG_MODULE:config_map(?BACKEND_CONFIG_KEY),
    {ok, Token} = file:read_file(get_config_key(k8s_token_path, M)),
    Token1 = binary:replace(Token, <<"\n">>, <<>>),
    {ok, NameSpace} = file:read_file(
			get_config_key(k8s_namespace_path, M)),
    NameSpace1 = binary:replace(NameSpace, <<"\n">>, <<>>),
    {ok, HostName} = inet:gethostname(),   
    Name = list_to_binary(
        io_lib:format(HostName ++ ".~B",[os:system_time(millisecond)])),

    
    V1Event = #{
        metadata => #{
            name => Name,
            namespace => NameSpace1
        },
        type => list_to_binary(Type),
        message => list_to_binary(Message),
        reason => list_to_binary(Reason),
        count => 1,
        lastTimestamp =>  list_to_binary(
            calendar:system_time_to_rfc3339(erlang:system_time(second))),
        involvedObject => #{
            apiVersion => <<"v1">>,
            kind => <<"RabbitMQ">>,
            name =>  list_to_binary("pod/" ++ HostName),
            namespace => NameSpace1
        },
        source => #{
            component => list_to_binary(HostName ++ "/rabbitmq_plugin"),
            host => list_to_binary(HostName)
        }           
    },


    ?HTTPC_MODULE:post(
      get_config_key(k8s_scheme, M),
      get_config_key(k8s_host, M),
      get_config_key(k8s_port, M),
      base_path(events,""),
      [],
      [{"Authorization", "Bearer " ++ binary_to_list(Token1)}],
      [{ssl, [{cacertfile, get_config_key(k8s_cert_path, M)}]}],
        binary_to_list(rabbit_json:encode(V1Event))
      ).  


receive_monitoring_messages()->
    receive
        {nodeup, Node} ->
            send_event("Normal", "NodeUP", io_lib:format("Node ~s is UP ",[Node]));
        {nodedown, Node} ->
            send_event("Warning", "NodeDown", io_lib:format("Node ~s is Down ",[Node]))
    end,
    receive_monitoring_messages().

monitor_nodes() ->
    _ = net_kernel:monitor_nodes(true, []),
    receive_monitoring_messages().
    