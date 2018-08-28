%%
%% Orignal developer: Ericsson AB 2006-2012
%% Modified by: Heroku 2012
%% Modifications: Extracted http_uri from OTP distribution to serve as
%% the basis for a standalone URI parsing/encoding library.
%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2006-2012. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%
%%
%% This is from chapter 3, Syntax Components, of RFC 3986:
%%
%% The generic URI syntax consists of a hierarchical sequence of
%% components referred to as the scheme, authority, path, query, and
%% fragment.
%%
%%    URI         = scheme ":" hier-part [ "?" query ] [ "#" fragment ]
%%
%%    hier-part   = "//" authority path-abempty
%%                   / path-absolute
%%                   / path-rootless
%%                   / path-empty
%%
%%    The scheme and path components are required, though the path may be
%%    empty (no characters).  When authority is present, the path must
%%    either be empty or begin with a slash ("/") character.  When
%%    authority is not present, the path cannot begin with two slash
%%    characters ("//").  These restrictions result in five different ABNF
%%    rules for a path (Section 3.3), only one of which will match any
%%    given URI reference.
%%
%%    The following are two example URIs and their component parts:
%%
%%          foo://example.com:8042/over/there?name=ferret#nose
%%          \_/   \______________/\_________/ \_________/ \__/
%%           |           |            |            |        |
%%        scheme     authority       path        query   fragment
%%           |   _____________________|__
%%          / \ /                        \
%%          urn:example:animal:ferret:nose
%%
%%    scheme      = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
%%    authority   = [ userinfo "@" ] host [ ":" port ]
%%    userinfo    = *( unreserved / pct-encoded / sub-delims / ":" )
%%
%%

-module(uri_parser).

-export([parse/1, parse/2,
         encode/1, decode/1]).

%%%=========================================================================
%%%  API
%%%=========================================================================

parse(AbsURI) ->
    parse(AbsURI, []).

parse(AbsURI, Opts) ->
    case parse_scheme(AbsURI, Opts) of
        {error, Reason} ->
            {error, Reason};
        {Scheme, DefaultPort, Rest} ->
            case (catch parse_uri_rest(Scheme, DefaultPort, Rest, Opts)) of
                {ok, {UserInfo, Host, Port, Path, Query}} ->
                    {ok, {Scheme, UserInfo, Host, Port, Path, Query}};
                {error, Reason} ->
                    {error, {Reason, Scheme, AbsURI}};
                _  ->
                    {error, {malformed_url, Scheme, AbsURI}}
            end
    end.

reserved() ->
    sets:from_list([$;, $:, $@, $&, $=, $+, $,, $/, $?,
                    $#, $[, $], $<, $>, $\", ${, $}, $|,
                               $\\, $', $^, $%, $ ]).

encode(URI) ->
    Reserved = reserved(),
    lists:append([uri_encode(Char, Reserved) || Char <- URI]).

decode(String) ->
    do_decode(String).

do_decode([$%,Hex1,Hex2|Rest]) ->
    [hex2dec(Hex1)*16+hex2dec(Hex2)|do_decode(Rest)];
do_decode([First|Rest]) ->
    [First|do_decode(Rest)];
do_decode([]) ->
    [].


%%%========================================================================
%%% Internal functions
%%%========================================================================

scheme_defaults(Opts) ->
    case lists:keysearch(scheme_defaults, 1, Opts) of
        {value, {scheme_defaults, SchemeDefaults}} ->
            SchemeDefaults;
        false ->
            uri_defaults:scheme_defaults()
    end.

parse_scheme(AbsURI, Opts) ->
    case split_uri(AbsURI, ":", {error, no_scheme}, 1, 1) of
        {error, no_scheme} ->
            {error, no_scheme};
        {SchemeStr, Rest} ->
            try list_to_existing_atom(http_util:to_lower(SchemeStr)) of
                Scheme when is_atom(Scheme) ->
                    DefaultPort = proplists:get_value(Scheme,
                                                      scheme_defaults(Opts),
                                                      no_default_port),
                    {Scheme, DefaultPort, Rest}
            catch
                error:badarg ->
                    {error, {unknown_scheme, SchemeStr}}
            end
    end.

parse_uri_rest(Scheme, DefaultPort, "//" ++ URIPart, Opts) ->
    {Authority, PathQuery} =
        case split_uri(URIPart, "/", URIPart, 1, 0) of
            Split = {_, _} ->
                Split;
            URIPart ->
                case split_uri(URIPart, "\\?", URIPart, 1, 0) of
                    Split = {_, _} ->
                        Split;
                    URIPart ->
                        {URIPart,""}
                end
        end,
    {UserInfo, HostPort} = split_uri(Authority, "@", {"", Authority}, 1, 1),
    {Host, Port}         = parse_host_port(Scheme, DefaultPort, HostPort, Opts),
    {Path, Query}        = parse_path_query(PathQuery),
    {ok, {UserInfo, Host, Port, Path, Query}}.


parse_path_query(PathQuery) ->
    {Path, Query} =  split_uri(PathQuery, "\\?", {PathQuery, ""}, 1, 0),
    {path(Path), Query}.

%% In this version of the function, we no longer need
%% the Scheme argument, but just in case...
parse_host_port(_Scheme, DefaultPort, "[" ++ HostPort, Opts) -> %ipv6
    {Host, ColonPort} = split_uri(HostPort, "\\]", {HostPort, ""}, 1, 1),
    Host2 = maybe_ipv6_host_with_brackets(Host, Opts),
    {_, Port} = split_uri(ColonPort, ":", {"", DefaultPort}, 0, 1),
    {Host2, int_port(Port)};

parse_host_port(_Scheme, DefaultPort, HostPort, _Opts) ->
    {Host, Port} = split_uri(HostPort, ":", {HostPort, DefaultPort}, 1, 1),
    {Host, int_port(Port)}.

split_uri(UriPart, SplitChar, NoMatchResult, SkipLeft, SkipRight) ->
    case regexp:first_match(UriPart, SplitChar) of
        {match, Match, _} ->
            {string:substr(UriPart, 1, Match - SkipLeft),
             string:substr(UriPart, Match + SkipRight, length(UriPart))};
        nomatch ->
            NoMatchResult
    end.

maybe_ipv6_host_with_brackets(Host, Opts) ->
    case lists:keysearch(ipv6_host_with_brackets, 1, Opts) of
        {value, {ipv6_host_with_brackets, true}} ->
            "[" ++ Host ++ "]";
        _ ->
            Host
    end.


int_port(Port) when is_integer(Port) ->
    Port;
int_port(Port) when is_list(Port) ->
    list_to_integer(Port);
%% This is the case where no port was found and there was no default port
int_port(no_default_port) ->
    throw({error, no_default_port}).

path("") ->
    "";
path(Path) ->
    Path.

uri_encode(Char, Reserved) ->
    case sets:is_element(Char, Reserved) of
        true ->
            [ $% | http_util:integer_to_hexlist(Char)];
        false ->
            [Char]
    end.

hex2dec(X) when (X>=$0) andalso (X=<$9) -> X-$0;
hex2dec(X) when (X>=$A) andalso (X=<$F) -> X-$A+10;
hex2dec(X) when (X>=$a) andalso (X=<$f) -> X-$a+10.
