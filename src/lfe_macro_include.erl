%% Copyright (c) 2013 Robert Virding
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% File    : lfe_macro_include.erl
%% Author  : Robert Virding
%% Purpose : Lisp Flavoured Erlang macro expander for include macros.

%% Expand the (include-file ...) and (include-lib ...) macros handling
%% if they are LFE syntax files or erlang syntax files. Erlang syntax
%% files are ones which end in .hrl. We only handle basic record and
%% macro definitions.

-module(lfe_macro_include).

-export([file/3,lib/3,format_error/1,stringify/1]).

-compile([export_all]).

-include("lfe_macro.hrl").

read_hrl_file_1(Name) ->
    case epp:open(Name, []) of
	{ok,Epp} ->
	    %% These are two undocumented functions of epp.
	    Fs = epp:parse_file(Epp),
	    Ms = epp:macro_defs(Epp),
	    epp:close(Epp),			%Now we close epp
	    {ok,Fs,Ms};
	{error,E} -> {error,E}
    end.

%% Errors.
format_error({notrans_function,F,A}) ->
    io_lib:format("unable to translate function ~w/~w", [F,A]);
format_error({notrans_record,R}) ->
    io_lib:format("unable to translate record ~w", [R]);
format_error({notrans_macro,M}) ->
    io_lib:format("unable to translate macro ~w", [M]).

%% add_warning(Warning, State) -> State.
%% add_warning(Line, Warning, State) -> State.

add_warning(W, St) -> add_warning(St#mac.line, W, St).

add_warning(L, W, St) ->
    St#mac{warnings=St#mac.warnings ++ [{L,?MODULE,W}]}.

%% file([FileName], Env, State) -> {yes,(progn ...),State} | no.
%%  Expand the (include-file ...) macro.  This is a VERY simple
%%  include file macro! We just signal errors.

file(Body, _, St0) ->
    case include_name(Body) of
	{ok,Name} ->
	    case read_file(Name, St0) of	%Try to read file
		{ok,Fs,St1} -> {yes,['progn'|Fs],St1};
		{error,E} -> error(E)
	    end;
	{error,E} -> error(E)
    end.

%% lib([FileName], Env, State) -> {yes,(progn ...),State} | no.
%%  Expand the (include-lib ...) macro.  This is a VERY simple include
%%  lib macro! First try to include the file directly else assume
%%  first directory name is a library name. We just signal errors.

lib(Body, _, St0) ->
    case include_name(Body) of
	{ok,Name} ->
	    case read_file(Name, St0) of
		{ok,Fs,St1} -> {yes,['progn'|Fs],St1};
		{error,_} ->
		    case lib_file_name(Name) of
			{ok,Lfile} ->
			    case read_file(Lfile, St0) of
				{ok,Fs,St1} -> {yes,['progn'|Fs],St1};
				{error,E} -> error(E)
			    end;
			{error,_} -> error(badarg)
		    end
	    end;
	{error,E} -> error(E)
    end.

%% include_name(Body) -> bool().
%%  Gets the file name from the include-XXX body.

include_name([Name]) ->
    case io_lib:char_list(Name) of
	true -> {ok,Name};
	false -> {error,badarg}
    end;
include_name(_) -> {error,badarg}.

%% lib_file_name(LibPath) -> {ok,LibFileName} | {error,Error}.
%%  Construct path to true library file.

lib_file_name(Lpath) ->
    [Lname|Rest] = filename:split(Lpath),
    case code:lib_dir(list_to_atom(Lname)) of
	Ldir when is_list(Ldir) ->
	    {ok,filename:join([Ldir|Rest])};
	{error,E} -> {error,E}
    end.

%% read_file(FileName, State) -> {ok,Forms,State} | {error,Error}.

read_file(Name, St) ->
    case lists:suffix(".hrl", Name) of
	true -> read_hrl_file(Name, St);       %Read file as .hrl file
	false -> read_lfe_file(Name, St)
    end.

read_lfe_file(Name, St) ->
    %% Read the file as an LFE file.
    case lfe_io:read_file(Name) of
	{ok,Fs} -> {ok,Fs,St};
	{error,E} -> {error,E}
    end.

%% read_hrl_file(FileName, State) -> {ok,Forms,State} | {error,Error}.
%%  We use two undocumented functions of epp which allow us to get
%%  inside and get out the macros.

read_hrl_file(Name, St) ->
    case epp:open(Name, []) of
	{ok,Epp} ->
	    %% These are two undocumented functions of epp.
	    Fs = epp:parse_file(Epp),		%This must be called first
	    Ms = epp:macro_defs(Epp),		% then this!
	    epp:close(Epp),			%Now we close epp
	    parse_hrl_file(Fs, Ms, St);
	{error,E} -> {error,E}
    end.

%% parse_hrl_file(Forms, Macros, State) -> {ok,Forms,State} | {error,Error}.

parse_hrl_file(Fs0, Ms0, St0) ->
    {Fs1,St1} = trans_forms(Fs0, St0),
    {Ms1,St2} = trans_macros(Ms0, St1),
    {ok,Fs1 ++ Ms1,St2}.

%% trans_forms(Forms, State) -> {LForms,State}.
%%  Translate the record and function defintions in the forms to LFE
%%  record and function definitions. Ignore all type declarations and
%%  other forms.

trans_forms([{attribute,_,record,{Name,Fields}}|Fs], St0) ->
    {Lfs,St1} = trans_forms(Fs, St0),
    case catch {ok,trans_record(Name, Fields)} of
	{ok,Lrec} -> {[Lrec|Lfs],St1};
	{'EXIT',_} ->				%Something went wrong
	    {Lfs,add_warning({notrans_record,Name}, St1)}
    end;
trans_forms([{function,_,Name,Arity,Cls}|Fs], St0) ->
    {Lfs,St1} = trans_forms(Fs, St0),
    case catch {ok,trans_function(Name, Arity, Cls)} of
	{ok,Lfunc} -> {[Lfunc|Lfs],St1};
	{'EXIT',_} ->				%Something went wrong
	    {Lfs,add_warning({notrans_function,Name,Arity}, St1)}
    end;
trans_forms([{error,_}|Fs], St) ->		%What should we do with these?
    trans_forms(Fs, St);
trans_forms([_|Fs], St) ->			%Ignore everything else
     trans_forms(Fs, St);
trans_forms([], St) -> {[],St}.

%% trans_record(Name, Fields) -> LRecDef.

trans_record(Name, Fs) ->
    Lfs = record_fields(Fs),
    [defrecord,Name|Lfs].

record_fields(Fs) ->
    [ record_field(F) || F <- Fs ].

record_field({record_field,_,F}) ->		%Just the field name
    lfe_trans:from_lit(F);
record_field({record_field,_,F,Def}) ->		%Field name and default value
    Fd = lfe_trans:from_lit(F),
    Ld = lfe_trans:from_expr(Def),
    [Fd,Ld].

%% trans_function(Name, Arity, Clauses) -> LfuncDef.

trans_function(Name, _, Cls) ->
    %% Make it a fun and then drop the match-lambda.
    ['match-lambda'|Lcs] = lfe_trans:from_expr({'fun',0,{clauses,Cls}}),
    [defun,Name|Lcs].

%% trans_macros(MacroDefs, State) -> {LMacroDefs,State}.
%%  Translate macro definitions to LFE macro definitions. Ignore
%%  undefined and predefined macros.

trans_macros([{{atom,Mac},Defs}|Ms], St0) ->
    {Lms,St1} = trans_macros(Ms, St0),
    case catch trans_macro(Mac, Defs, St1) of
	{'EXIT',_} ->				%It crashed
	    {Lms,add_warning({notrans_macro,Mac}, St1)};
	{none,St2} -> {Lms,St2};		%No definition, ignore
	{Mdef,St2} -> {[Mdef|Lms],St2}
    end;
trans_macros([], St) -> {[],St}.

trans_macro(_, undefined, St) -> {none,St};	%Undefined macros
trans_macro(_, {none,_}, St) -> {none,St};	%Predefined macros
trans_macro(Mac, Defs0, St) ->
    Defs1 = order_macro_defs(Defs0),
    case trans_macro_defs(Defs1) of
	[] -> {none,St};			%No definitions
	Lcls -> {[defmacro,Mac|Lcls],St}
    end.

order_macro_defs([{none,Ds}|Defs]) ->		%Put the no arg version last
    Defs ++ [{none,Ds}];
order_macro_defs(Defs) -> Defs.

%% trans_macro_defs(MacroDef) -> [] | [Clause].
%%  Translate macro definition to a list of clauses. Put the no arg
%%  version last as a catch all. Clash if macro has no arg definition
%%  *and* function definition with no args:
%%  -define(foo, 42).
%%  -define(foo(), 17).
%%
%%  NOTE: Don't yet generate code to macros with *only* no arg case to
%%  be used as functions. So -define(foo, bar) won't work for foo(42).

trans_macro_defs([{none,{none,Ts}}|Defs]) ->
    Ld = trans_macro_body([], Ts),
    AnyArgs = ['_'|Ld],
    [AnyArgs|trans_macro_defs(Defs)];
trans_macro_defs([{N,{As,Ts}}|Defs]) when is_integer(N) ->
    Ld = trans_macro_body(As, Ts),
    ListArgs = [[list|As]|Ld],
    [ListArgs|trans_macro_defs(Defs)];
trans_macro_defs([]) -> [].

trans_macro_body(As, Ts0) ->
    Ts1 = trans_qm(Ts0),
    %% Wrap variables in arg list with an (unquote ...) call.
    Wrap = fun ({var,L,V}=T, Ts) ->
		   case lists:member(V, As) of
		       true ->
			   [{atom,L,unquote},{'(',L},T,{')',L}|Ts];
		       false -> [T|Ts]
		   end;
	       (T, Ts) -> [T|Ts]
	   end,
    Ts2 = lists:foldr(Wrap, [], Ts1),
    %% Only allow single expressions, otherwise screws up backquoting.
    {ok,[E]} = erl_parse:parse_exprs(Ts2 ++ [{dot,0}]),
    [?BQ(lfe_trans:from_expr(E))].

    %% case erl_parse:parse_exprs(Ts2 ++ [{dot,0}]) of
    %% 	{ok,[E]} ->
    %% 	    io:format("~p\n", [E]),
    %% 	    [?BQ(lfe_trans:from_expr(E))];
    %% 	Other -> io:format("~p\n~w\n", [Other,Ts2]),
    %% 		 []
    %% end.

    %% {ok,[_]=F} = erl_parse:parse_exprs(Ts1 ++ [{dot,0}]),
    %% backquote_last(lfe_trans:from_body(F)).

%% Backquote the last expression in the body.
%% backquote_last([E]) -> [?BQ(E)];
%% backquote_last([E|Es]) -> [E|backquote_last(Es)].

%% trans_qm(Tokens) -> Tokens.
%%  Translate variable argument names to atoms to get correct
%%  translation later on: ?Sune -> ?'Sune' -> (Sune)

trans_qm([{'?',_},{atom,_,_}=A,{'(',_}=P|Ts]) ->
    [A,P|trans_qm(Ts)];
trans_qm([{'?',_},{var,L,V},{'(',_}=P|Ts]) ->
    [{atom,L,V},P|trans_qm(Ts)];
trans_qm([{'?',L},{atom,_,_}=A|Ts]) ->
    [A,{'(',L},{')',L}|trans_qm(Ts)];
trans_qm([{'?',L},{var,_,V}|Ts]) ->
    [{atom,L,V},{'(',L},{')',L}|trans_qm(Ts)];
trans_qm([{'?',L},{'?',_},Arg|Ts]) ->
    %% Expand to call lfe_macro_include:stringify(quote(Arg)).
    [{atom,L,?MODULE},{':',L},{atom,L,stringify},{'(',L},
     {atom,L,quote},{'(',L},Arg,{')',L},
     {')',L}|
     trans_qm(Ts)];
trans_qm([T|Ts]) -> [T|trans_qm(Ts)];
trans_qm([]) -> [].

%%% stringify(Sexpr) -> String.
%%  Returns a list of sexpr, a string which when parse would return
%%  the sexpr.

stringify(E) -> lists:flatten(lfe_io:print1(E)).
