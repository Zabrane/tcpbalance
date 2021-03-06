%%%-------------------------------------------------------------------------
%%% File     : bal_proxy.erl
%%% Purpose  : A simple load balancing TCP proxy server
%%% Author   : Scott Lystig Fritchie, email: lhs=slfritchie, rhs=snookles.com
%%% Copyright: (c) 2003 Caspian Networks, Inc.
%%%-------------------------------------------------------------------------

-module(bal_proxy).
-behaviour(gen_server).

-include("balance.hrl").

%% Atom used internally to denote that the no back-end is immediately available
-define(MUST_WAIT, must_wait).

%% External exports
-export([start_link/1, start_link/5]).
-export([get_be/1, remote_ok/1, remote_error/2]).
-export([get_state/1, get_host/2, reset_host/2, reset_host/3, reset_all/1,
	 add_be/3, del_be/2]).
%% Inets (Web server) functions
-export([http_get_state/2]).

%% Debugging exports

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

%% start_link/1 used by supervisor
start_link([RegisterName, LocalIP, LocalPort, ConnTimeout, ActTimeout]) ->
    start_link(RegisterName, LocalIP, LocalPort, ConnTimeout, ActTimeout).

%% start_link/5 used by everyone else
start_link(RegisterName, LocalIP, LocalPort, ConnTimeout, ActTimeout) ->
    gen_server:start_link(?MODULE, {RegisterName, LocalIP, LocalPort, ConnTimeout, ActTimeout}, []).

%% Choose an available back-end host
get_be(BalancerPid) ->
    gen_server:call(BalancerPid, {self(), get_be}, infinity).

%% Tell the balancer that our assigned back-end is OK.
%% Note that we don't pass the hostname back to the balancer.  That's
%% because the balancer only needs our PID, self(), to figure
%% everything else out.
remote_ok(BalancerPid) ->
    gen_server:call(BalancerPid, {self(), remote_host, ok}, infinity).

%% Tell the balancer that our assigned back-end cannot be used.
remote_error(BalancerPid, Error) ->
    gen_server:call(BalancerPid, {self(), remote_host, error, Error},infinity).

%% Get the overall status summary of the balancer
get_state(BalancerPid) ->
    gen_server:call(BalancerPid, {get_state},infinity).

%% Get the status summary for a particular back-end host.
get_host(BalancerPid, Id) ->
    gen_server:call(BalancerPid, {get_host, Id},infinity).

%% Reset a back-end host's status to 'up'
reset_host(BalancerPid, Id) ->
    gen_server:call(BalancerPid, {reset_host, Id},infinity).

%% Reset a back-end host's status to Status
%% Status = up|down
reset_host(BalancerPid, Id, Status) ->
    gen_server:call(BalancerPid, {reset_host, Id, Status},infinity).

%% Reset all back-end hosts' status to 'up'
reset_all(BalancerPid) ->
    gen_server:call(BalancerPid, {reset_all},infinity).

%% Add a back-end host to the balancer's list, inserting it _after_
%% the position of AfterHost.  If AfterHost is [] or "" (same thing!),
%% then NewBE will be the first host in the list.
%% NOTE: There is a limited attempt to check that NewBE is a sanely-
%%       formatted "be" record, but it's still possible to send a
%%       bogus "be" record to the balancer.  Caveat utilitor.
add_be(BalancerPid, #be{}=NewBE, AfterId) ->
    gen_server:call(BalancerPid, {add_be, NewBE, AfterId},infinity).

%% Delete a back-end host from the balancer's list.
del_be(BalancerPid, Id) ->
    gen_server:call(BalancerPid, {del_be, Id},infinity).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_server
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%----------------------------------------------------------------------
init({RegisterName, LocalIP, LocalPort, ConnTimeout, ActTimeout}) ->
    Pid = ?TCPPROXY:init(LocalIP, LocalPort, self()),
    process_flag(trap_exit, true),
    %%register(list_to_atom("tcp_" ++ integer_to_list(LocalPort)), self()),
    % register(balance, self()),
	register(RegisterName, self()),
    %%
    %% Unfortunately, we cannot always rely the death of a tcp_proxy proc
    %% to tell us when we need to remove a waiting request.  For example,
    %% the tcp_proxy proc calls bal_proxy:get_be() and blocks when there
    %% are no back-ends available.  If the client closes the TCP connection,
    %% the tcp_proxy process does not receive the {tcp_closed, Sock} message
    %% because it's still blocking waiting for a reply from
    %% bal_proxy:get_be().  Therefore we use a 1-second repeating timer
    %% to remind us to check for connection timeouts when all backends are
    %% busy/unavailable.  Once we send a reply to the tcp_proxy proc, it
    %% can clean up, even though (optimally) it should have cleaned up
    %% several seconds ago.
    %%
    {ok, TOTimer} = timer:send_interval(1000, {check_waiter_timeouts}),
    {ok, #bp_state{register_name = RegisterName, local_ip = LocalIP, local_port = LocalPort, conn_timeout = ConnTimeout,
		act_timeout = ActTimeout, wait_list = queue:new(),
		be_list = get_be_list(), start_time = now(),
		to_timer = TOTimer, acceptor = Pid}}.

%%----------------------------------------------------------------------
%% Func: handle_call/3
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_call({Pid, get_be}, From, State) ->
    {Reply, NewState} = choose_backend(From, Pid, State),
    case Reply of
	?MUST_WAIT ->
	    {noreply, NewState};
	Reply ->
	    {reply, Reply, NewState}
    end;
handle_call({Pid, remote_host, ok}, _From, State) ->
    NewState = update_host(State, Pid, ok),
    Reply = ok,
    {reply, Reply, NewState};
handle_call({Pid, remote_host, error, Error}, _From, State) ->
    NewState = update_host(State, Pid, Error),
    Reply = ok,
    {reply, Reply, NewState};
handle_call({get_state}, _From, State) ->
    Reply = State,
    {reply, Reply, State};
handle_call({get_host, Id}, _From, State) ->
    Reply = lists:keysearch(Id, #be.id, State#bp_state.be_list),
    {reply, Reply, State};
handle_call({reset_host, Id}, _From, State) ->
    {Reply, NewState} = reset_be(Id, State, up),
    {reply, Reply, NewState};
handle_call({reset_host, Id, up}, _From, State) ->
    {Reply, NewState} = reset_be(Id, State, up),
    %% This is a dirty trick.  :-) Since we know that a backend is now
    %% up and available, we'll send a process exit message to ourself.
    %% Receipt of such a message will trigger the first waiter, if
    %% any, to be assigned a backend.
    self() ! {'EXIT', no_such_pid, another_host_is_up_now},
    {reply, Reply, NewState};
handle_call({reset_host, Id, down}, _From, State) ->
    {Reply, NewState} = reset_be(Id, State, down),
    {reply, Reply, NewState};
handle_call({reset_all}, _From, State) ->
    {Reply, NewState} = reset_all_bes(State),
    {reply, Reply, NewState};
handle_call({add_be, NewBE, AfterId}, _From, State) ->
    {Reply, NewState} = do_add_be(State, NewBE, AfterId),
    {reply, Reply, NewState};
handle_call({del_be, Id}, _From, State) ->
    {Reply, NewState} = do_del_be(State, Id),
    {reply, Reply, NewState};
handle_call(Request, From, State) ->
    error_logger:format("~s:handle_call: got ~w from ~w\n", [?MODULE, Request, From]),
    Reply = error,
    {reply, Reply, State}.

%%----------------------------------------------------------------------
%% Func: handle_cast/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_cast(Msg, State) ->
    error_logger:format("~s:handle_cast: got ~w\n", [?MODULE, Msg]),
    {noreply, State}.

%%----------------------------------------------------------------------
%% Func: handle_info/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_info({'EXIT', Pid, shutdown}, State) when Pid == State#bp_state.acceptor ->
    error_logger:format("~s:handle_info: acceptor pid ~w shutdown\n",
			[?MODULE, Pid]),
    {stop, normal, State};
handle_info({'EXIT', Pid, Reason}, State) ->
    case State#bp_state.acceptor of
	Pid ->
	    %% Acceptor died but not because of shutdown request.
	    error_logger:format("~s:handle_info: acceptor pid ~w died, reason = ~w\n",
				[?MODULE, Pid, Reason]),
	    {stop, {acceptor_failed, Pid, Reason}, State};
	_ ->
	    NewState = update_host(State, Pid, exited),
	    %% Tricky problem here.  If there is someone waiting, we need
	    %% to choose a new backend and tell that waiter to use it.
	    %% However, all backends may be down, in which case the waiter
	    %% must still wait.  So, we cheat by peeking into the wait_list
	    %% queue, assuming that an empty queue looks like {[], []}.
	    %% We wouldn't need this hack if a function like queue:size()
	    %% were available....
	    case NewState#bp_state.wait_list of
		{[], []} ->
		    {noreply, NewState};
		_ ->
		    {{value, {From, FromPid, _InsTime}}, NewQ} =
			queue:out(NewState#bp_state.wait_list),
		    {Reply, NewState2} = choose_backend(From,FromPid,NewState),
		    case Reply of
			?MUST_WAIT ->
			    {noreply, NewState2}; % Don't use NewQ!
			Reply ->
			    %% Send our async reply to the
			    %% patiently-waiting client.
			    gen_server:reply(From, Reply),
			    {noreply, NewState2#bp_state{wait_list = NewQ}}
		    end
	    end
    end;
handle_info({check_waiter_timeouts}, State) ->
    NewState = check_waiter_timeouts(State),
    {noreply, NewState};
handle_info(Info, State) ->
    error_logger:format("~s:handle_info: got ~w\n", [?MODULE, Info]),
    {noreply, State}.

%%----------------------------------------------------------------------
%% Func: terminate/2
%% Purpose: Shutdown the server
%% Returns: any (ignored by gen_server)
%%----------------------------------------------------------------------
terminate(_Reason, State) ->
    timer:cancel(State#bp_state.to_timer),
    ok.

%%----------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%%----------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

get_be_list() ->
    case application:get_env(?BALANCER_APP, initial_be_list) of
	{ok, L} ->
	    L;
	_ ->
	    error_logger:format("~s:get_be_list: warning: cannot find 'initial_be_list' in application environment\n", [?MODULE]),
	    []
    end.

%% choose_backend/3 -- If a back-end host is immediately available,
%% return its relevant info to the caller.  Otherwise, tell caller
%% that it must wait, and put the caller into the wait_list queue.

choose_backend(From, FromPid, State) ->
    case choose_be(FromPid, State) of
	{ok, RHost, RPort, NewBEList} ->
	    Reply = {ok, RHost, RPort, State#bp_state.conn_timeout,
		     State#bp_state.act_timeout},
	    {Reply, State#bp_state{be_list = NewBEList}};
	_ ->
	    Q = queue:in({From, FromPid, nowtime()}, State#bp_state.wait_list),
	    {?MUST_WAIT, State#bp_state{wait_list = Q}}
    end.

%% Find the first available back-end host

choose_be(FromPid, State) ->
    choose_be(FromPid, State#bp_state.be_list, []).
choose_be(_FromPid, [], _BEList) ->
    sorry;
choose_be(FromPid, [B|Bs], BEList) ->
    if
	B#be.status == up, (B#be.pendconn + B#be.actconn < B#be.maxconn) ->
	    NewB = B#be{pendconn = B#be.pendconn + 1,
			pidlist = [{pending, FromPid}|B#be.pidlist]},
	    % NewBEList = lists:reverse([NewB | Bs], BEList),
		NewBEList = Bs ++ [NewB] ++ BEList,
	    {ok, B#be.name, B#be.port, NewBEList};
	true ->
	    choose_be(FromPid, Bs, [B|BEList])
    end.

%%%
%%% I'm fairly certain that I should be embarrassed by the various
%%% ways that I've created for updating the status of one or more
%%% back-end boxes (or resetting them, which seems to be handled just
%%% slightly differently, how odd).  And whether you twiddle the list
%%% by hostname or by record or something else.  {sigh}
%%%
%%% During the brute-force coding afternoon that spawned this, I'd
%%% changed my mind a few times too many.  If this application ever
%%% sees a refactoring, here's the place to start.
%%%

update_host(State, Pid, Status) ->
    {BEList, WaitList} =
	case update_belist(State#bp_state.be_list, [], Pid, Status) of
	    {ok, NewBEList} ->
		{NewBEList, State#bp_state.wait_list};
	    {notfound, _} ->
		NewQ = remove_from_wait_list(Pid, State#bp_state.wait_list),
		{State#bp_state.be_list, NewQ}
	end,
    State#bp_state{be_list = BEList, wait_list = WaitList}.

update_belist([], BEList, _Pid, _Status) ->
    {notfound, lists:reverse(BEList)};
update_belist([B|Bs], BEList, Pid, Status) ->
    case lists:keymember(Pid, 2, B#be.pidlist) of
	true ->
	    NewB = update_be(B, Pid, Status),
	    {ok, lists:reverse([NewB|BEList], Bs)};
	false ->
	    update_belist(Bs, [B|BEList], Pid, Status)
    end.

update_be(B, Pid, ok) ->
    Pending = B#be.pendconn,
    Active = B#be.actconn,
    B#be{pendconn = Pending - 1, actconn = Active + 1,
	 act_count = B#be.act_count + 1,
	 pidlist = lists:keyreplace(Pid, 2, B#be.pidlist, {active,Pid,now()})};
update_be(B, Pid, exited) ->
    Active = B#be.actconn,
	% {value,{pending,<0.172.0>}}
    case lists:keysearch(Pid, 2, B#be.pidlist) of
		{value, {active, Pid, StartTime}} ->
    		Elapsed = calc_elapsed(StartTime, now()),
    		B#be{actconn = Active - 1,
	 			 act_time = B#be.act_time + Elapsed,
	 		     pidlist = lists:keydelete(Pid, 2, B#be.pidlist)};
		 {value,{pending,Pid}} ->
			 Pending = B#be.pendconn,
			 B#be{pendconn = Pending - 1,
 	 		      pidlist = lists:keydelete(Pid, 2, B#be.pidlist)}
	end;
%% Sometimes a backend is added before the host is actually available; don't remove it from the pool yet
update_be(B, Pid, {error,econnrefused}=ErrorStatus) ->
    error_logger:format("update_be: Pid ~w for host ~s ~w, error status ~w\n", [Pid, B#be.name, B#be.port, ErrorStatus]),
    B#be{lasterr = ErrorStatus, lasterrtime = now()};
update_be(B, Pid, ErrorStatus) ->
    error_logger:format("update_be: Pid ~w for host ~s ~w, error status ~w\n", [Pid, B#be.name, B#be.port, ErrorStatus]),
    Pending = B#be.pendconn,
    B#be{status = down, lasterr = ErrorStatus, lasterrtime = now(),
	 pendconn = Pending - 1,
	 pidlist = lists:keydelete(Pid, 2, B#be.pidlist)}.

remove_from_wait_list(Pid, Q) ->
    zap_q(Pid, Q, queue:new()).
zap_q(Pid, Q, NewQ) ->
    case queue:out(Q) of
	{{value, I}, RemQ} ->
	    case I of
		{_, Pid, _} ->
		    zap_q(Pid, RemQ, NewQ);
		_ ->
		    zap_q(Pid, RemQ, queue:in(I, NewQ))
	    end;
	{empty, _RemQ} ->
	    NewQ
    end.

calc_elapsed({MSecStart, SecStart, MicroSecStart},
	     {MSecFinish, SecFinish, MicroSecFinish}) ->
    %% There are more "efficient" ways to do this, but when you've
    %% got bignums, why not do it this way if it is infrequent?
    (MSecFinish * 1000000 + SecFinish + MicroSecFinish / 1000000) -
    (MSecStart * 1000000 + SecStart + MicroSecStart / 1000000).

reset_be(Id, State, Status) ->
    NewBEList = reset_be(Id, State#bp_state.be_list, Status, []),
    {ok, State#bp_state{be_list = NewBEList}}.
reset_be(_Id, [], _Status, BEList) ->
    lists:reverse(BEList);
reset_be(Id, [B|Bs], Status, BEList) ->
    case B#be.id of
	Id ->
	    lists:reverse([B#be{status = Status,
				%% do not reset: act_count = 0, act_time = 0,
				lasterr = reset,
				lasterrtime = now()}|BEList], Bs);
	_ ->
	    reset_be(Id, Bs, Status, [B|BEList])
    end.

reset_all_bes(State) ->
    Ids = [B#be.id || B <- State#bp_state.be_list],
    NewState = reset_each_be(Ids, State),
    {ok, NewState#bp_state{start_time = now()}}.

reset_each_be([], State) ->
    State;
reset_each_be([B|Bs], State) ->
    {_, NewState} = reset_be(B, State, up),
    reset_each_be(Bs, NewState).

do_add_be(State, #be{}=NewBE, AfterId) ->
    case catch sane_be(NewBE) of
	true ->
	    case lists:keymember(NewBE#be.id, #be.id,
				 State#bp_state.be_list) of
		true ->
			error_logger:format("BE already exists: ~p\n", [NewBE]),
		    {{error, id_exists}, State};
		_ ->
		    {ok, State#bp_state{be_list =
				     insert_be(NewBE, AfterId,
					       State#bp_state.be_list)}}
	    end;
	_ ->
		error_logger:format("Not sane BE: ~p\n", [NewBE]),
	    {{error, not_sane}, State}
    end.

do_del_be(State, Id) ->
    case lists:keymember(Id, #be.id,
			 State#bp_state.be_list) of
	true ->
	    {ok, State#bp_state{be_list =
			     lists:keydelete(Id, #be.id,
					     State#bp_state.be_list)}};
	_ ->
	    {{error, id_not_found}, State}
    end.

%%% Being lazy, no tail recursion.
%%% Interesting, there is no such insert func in stdlib "lists" module. {shrug}

insert_be(NewBE, _AfterId, []) ->
    [NewBE];
insert_be(NewBE, "", BEList) ->
    [NewBE|BEList];
insert_be(NewBE, AfterId, [B|Bs]) when B#be.id == AfterId ->
    [B|[NewBE|Bs]];
insert_be(NewBE, AfterId, [B|Bs]) ->
    [B|insert_be(NewBE, AfterId, Bs)].

%%% QQQ Is there a less brute-force-ish way to do this?
sane_be(#be{}=B) ->
    Real = #be{},
    if
	size(B) =/= size(Real) -> false;	% XXX Should use record_info()
	%% not list(B#be.name) -> false;
	not is_atom(B#be.id) -> false;
	B#be.name == "" -> false;
	B#be.port =< 0 -> false;
	%% not atom(B#be.status) -> false;
	B#be.maxconn =< 0 -> false;
	B#be.pendconn =/= 0 -> false;
	B#be.actconn =/= 0 -> false;
	B#be.act_count =/= 0 -> false;
	B#be.act_time =/= 0 -> false;
	B#be.pidlist =/= [] -> false;
	true -> true
    end;
sane_be(_B) ->
    false.

check_waiter_timeouts(State) ->
    TOTime = nowtime() - (State#bp_state.conn_timeout / 1000),
    NewQ = zap_timeout_q(TOTime, State#bp_state.wait_list),
    State#bp_state{wait_list = NewQ}.
zap_timeout_q(TOTime, Q) ->
    zap_timeout_q(TOTime, Q, queue:new()).
zap_timeout_q(TOTime, Q, NewQ) ->
    case queue:out(Q) of
	{{value, I}, RemQ} ->
	    case I of
		{From, _FromPid, Time} when Time < TOTime ->
		    gen_server:reply(From, ?TIMEOUT_BE),
		    zap_timeout_q(TOTime, RemQ, NewQ);
		_ ->
		    zap_timeout_q(TOTime, RemQ, queue:in(I, NewQ))
	    end;
	{empty, _RemQ} ->
	    NewQ
    end.

%%%
%%% HTTP server stuff
%%%

http_get_state(_Env, _Input) ->
    [
     header(),
     top("Current Proxy State"),
     format_proxy_state(bal_proxy:get_state({balance, node()})),
     footer()
    ].


format_proxy_state(State) ->
    %% QQQ Icky counting code
    {L1, L2} = State#bp_state.wait_list,
    [
     "<pre>\n",
     %% From README: insert line here!
     io_lib:format("Proxy start time: ~s\n", [fmt_date(State#bp_state.start_time)]),
     io_lib:format("Current time:     ~s\n", [fmt_date(now())]),
	 io_lib:format("Name: ~s\n", [State#bp_state.register_name]),
	 io_lib:format("Local IP address: ~s\n", [State#bp_state.local_ip]),
     io_lib:format("Local TCP port number: ~w\n", [State#bp_state.local_port]),
     io_lib:format("Connection timeout (seconds): ~w\n", [State#bp_state.conn_timeout / 1000]),
     io_lib:format("Activity timeout (seconds): ~w\n", [State#bp_state.act_timeout / 1000]),
     io_lib:format("Length of wait list: ~w\n", [length(L1) + length(L2)]),
     "</pre>\n",
     "<table>\n",
     "<tr> ",
     [["<td> <b>", X, "</b> "] || X <- ["Name", "Port", "Status", "MaxConn",
				       "PendConn", "ActConn", "LastErr",
				       "LastErrTime", "ActiveCount",
				       "ActiveTime"]],
     "\n",
     format_be_list(State#bp_state.be_list),
     "</table>\n"
    ].

format_be_list(List) ->
    format_be_list(List, []).
format_be_list([], Acc) ->
    lists:reverse(Acc);
format_be_list([B|Bs], Acc) ->
    LastErrTime = if
		      B#be.lasterrtime -> B#be.lasterrtime;
		      true -> {0,0,0}
		  end,
    format_be_list(Bs, [[
			 "<tr> ",
			 io_lib:format("<td> ~s ", [B#be.id]),
			 io_lib:format("<td> ~s ", [B#be.name]),
			 io_lib:format("<td> ~w ", [B#be.port]),
			 io_lib:format("<td> ~w ", [B#be.status]),
			 io_lib:format("<td> ~w ", [B#be.maxconn]),
			 io_lib:format("<td> ~w ", [B#be.pendconn]),
			 io_lib:format("<td> ~w ", [B#be.actconn]),
			 io_lib:format("<td> ~w ", [B#be.lasterr]),
			 io_lib:format("<td> ~s ", [fmt_date(LastErrTime)]),
			 io_lib:format("<td> ~w ", [B#be.act_count]),
			 io_lib:format("<td> ~w ", [B#be.act_time]),
			 "</tr>\n"
			]|Acc]).

header() ->
  header("text/html").
header(MimeType) ->
  "Content-type: " ++ MimeType ++ "\r\n\r\n".

top(Title) ->
  "<HTML>
<HEAD>
<TITLE>" ++ Title ++ "</TITLE>
</HEAD>
<BODY>\n".

footer() ->
  "</BODY>
</HTML>\n".

%%% Misc helpers

fmt_date(TimeStamp) ->
    {{Y, M, D}, {Hr, Min, Sec}} = calendar:now_to_local_time(TimeStamp),
    %% !@#$! io_lib:format doesn't do leading zeros like sprintf() can.
    MinStr = pad_zero(lists:flatten(io_lib:format("~w", [Min]))),
    SecStr = pad_zero(lists:flatten(io_lib:format("~w", [Sec]))),
    io_lib:format("~w/~w/~w ~w:~s:~s", [Y, M, D, Hr, MinStr, SecStr]).

%% Two digits only, too bad io_lib can't do this for us
pad_zero(L) when length(L) == 1 ->
    "0" ++ L;
pad_zero(L) ->
    L.

nowtime() ->
    {MSec, Sec, _} = now(),
    MSec * 1000000 + Sec.
