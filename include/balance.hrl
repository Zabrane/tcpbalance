%%%-------------------------------------------------------------------------
%%% File     : balance.hrl
%%% Purpose  : TCP load balancing application.
%%% Author   : Scott Lystig Fritchie, email: lhs=slf, rhs=caspiannetworks.com
%%% Copyright: (c) 2003 Caspian Networks, Inc.
%%%-------------------------------------------------------------------------

%% Name of the balancer application
-define(BALANCER_APP, balance).

%% Module name for the TCP proxy
-define(TCPPROXY, tcp_proxy).

%% Atom used to inform tcp_proxy proc that no backends are available.
-define(TIMEOUT_BE, timeout_be).

%% State of a single back-end host
-record(be, {
      id,                   % Identifier for multiple names per host
	  name,					% Name/IP string or IP tuple
	  port,					% TCP port number
	  status,				% up|down
	  maxconn,				% Maximum connections
	  pendconn = 0,				% Pending connections
	  actconn = 0,				% Active connections
	  lasterr,				% Last error (term)
	  lasterrtime,				% Timestamp of last error
	  act_count = 0,			% Times backend has been active
	  act_time = 0,				% Cumulative activity time
	  pidlist = []				% Pending & active pid list
	 }).

%% Overall state of the proxy
-record(bp_state, {
	  register_name,            % Named pid of proxy
	  local_ip, 			    % Local IP address
	  local_port,				% Local TCP port number
	  conn_timeout = (1*1000),		% Connection timeout (ms)
	  act_timeout = (120*1000),		% Activity timeout (ms)
	  be_list,				% Back-end list
	  acceptor,				% Pid of listener proc
	  start_time,				% Proxy start timestamp
	  to_timer,				% Timeout timer ref
	  wait_list				% List of waiting clients
	 }).
