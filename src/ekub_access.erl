-module(ekub_access).

-export([
    read/0, read/1
]).

-export_type([
    access/0
]).

-type option() ::
    {kubeconfig, FileName :: string()} |
    {ca_cert_file, FileName :: string()} |
    {ca_cert, CaCert :: base64()} |
    {client_cert_file, FileName :: string()} |
    {client_cert, ClientCert :: base64()} |
    {client_key_file, FileName :: string()} |
    {client_key, ClientKey :: base64()} |
    {insecure_skip_tls_verify, SkipTls :: boolean()} |
    {token_file, FileName :: string()} |
    {token, Token :: string()} |
    {namespace_file, FileName :: string()} |
    {namespace, Namespace :: string()} |
    {username, UserName :: string()} |
    {password, Password :: string()} |
    {server, Server :: string()}.

-type access() :: #{access_key() => access_value()}.

-type access_key() ::
    ca_cert |
    client_cert |
    client_key |
    insecure_skip_tls_verify |
    token |
    namespace |
    username |
    password |
    server.

-type access_value() :: term().

-type base64() :: [1..255] | binary().

-define(Config, ekub_config).

-define(OptionsOrder, [
    kubeconfig,
    kubeconfig_doc,
    ca_cert_file,
    ca_cert,
    client_cert_file,
    client_cert,
    client_key_file,
    client_key,
    token_file,
    token,
    namespace_file,
    namespace,
    username,
    password,
    server
]).

%% -define(DefaultOptionsOrder, [kubeconfig, service_account]).

-define(DefaultServiceAccountDir,
    "/var/run/secrets/kubernetes.io/serviceaccount").

-spec default_options() -> DefaultOptions :: [[option()]].
default_options() -> [
    [{kubeconfig, ?Config:filename()}],

    [{server, "https://kubernetes"},
     {ca_cert_file, ?DefaultServiceAccountDir ++ "/ca.crt"},
     {token_file, ?DefaultServiceAccountDir ++ "/token"},
     {namespace_file, ?DefaultServiceAccountDir ++ "/namespace"}]
].

-spec read() ->
    Result :: {ok, access()} |
              {error, [{Option :: option(), Reason :: term()}]}.

read() ->
     case lists:foldl(fun read/2, {error, []}, default_options()) of
         {ok, Access} -> {ok, Access};
         {error, Reasons} -> {error, lists:reverse(Reasons)}
     end.

read(_Options, {ok, Access}) -> {ok, Access};
read(Options, {error, Reasons}) ->
    case read(Options) of
        {ok, Access} -> {ok, Access};
        {error, Reason} -> {error, [Reason|Reasons]}
    end.

-spec read(Options :: [option()]) ->
    Result :: {ok, access()} |
              {error, {Option :: option(), Reason :: term()}}.

read(Options) ->
    OptionsMap = maps:from_list(Options),
    OrderedOptions = [{Name, Value} || Name <- ?OptionsOrder,
                      {ok, Value} <- [maps:find(Name, OptionsMap)]],
    lists:foldl(fun read_option/2, {ok, #{}}, OrderedOptions).

read_option(Option, {ok, Access}) ->
    case read_option(Option) of
        {ok, Result} -> {ok, maps:merge(Access, Result)};
        {error, Reason} -> {error, {Option, Reason}}
    end;
read_option(_Option, {error, Reason}) -> {error, Reason}.

read_option({kubeconfig, FileName}) ->
    case ?Config:read(FileName) of
        {ok, [Config|_]} -> read_kubeconfig(Config);
        {error, Reason} -> {error, Reason}
    end;

read_option({kubeconfig_doc, Doc}) ->
    case ?Config:read_doc(Doc) of
        {ok, [Config|_]} -> read_kubeconfig(Config);
        {error, Reason} -> {error, Reason}
    end;

read_option({Name, Value}) when
    Name == ca_cert_file;
    Name == client_cert_file;
    Name == client_key_file
->
    case decode_cert_file(Value) of
        {ok, Result} -> {ok, #{trim_suffix(Name) => Result}};
        {error, Reason} -> {error, Reason}
    end;

read_option({Name, Value}) when
    Name == ca_cert;
    Name == client_cert;
    Name == client_key
->
    case decode_cert_b64(Value) of
        {ok, Result} -> {ok, #{Name => Result}};
        {error, Reason} -> {error, Reason}
    end;

read_option({Name, Value}) when
    Name == namespace_file;
    Name == token_file
->
    case file:read_file(Value) of
        {ok, Binary} -> {ok, #{trim_suffix(Name) => Binary}};
        {error, Reason} -> {error, Reason}
    end;

read_option({Name, Value}) -> 
    {ok, #{Name => Value}}.

read_kubeconfig(Config) ->
    case maps:find("current-context", Config) of
        {ok, ContextName} -> read_kubeconfig(ContextName, Config);
        false -> {error, no_current_context}
    end.

read_kubeconfig(ContextName, Config) ->
    Context = maps:get("context", ?Config:context(ContextName, Config)),
    #{"cluster" := ClusterName,
      "user" := UserName} = Context,

    complete_kubeconfig(
    maps:merge(
    maps:merge(
        Context,
        maps:get("cluster", ?Config:cluster(ClusterName, Config))),
        maps:get("user", ?Config:user(UserName, Config))
    )).

complete_kubeconfig(Config) ->
    maps:fold(fun complete_kubeconfig/3, {ok, #{}}, Config).

complete_kubeconfig(Name, Value, {ok, Config}) ->
    complete_kubeconfig(case Name of
        "certificate-authority-data" -> {ca_cert, decode_cert_b64(Value)};
        "client-certificate-data" -> {client_cert, decode_cert_b64(Value)};
        "client-key-data" -> {client_key, decode_cert_b64(Value)};
        "certificate-authority" -> {ca_cert, Value, decode_cert_file(Value)};
        "client-certificate" -> {client_cert, Value, decode_cert_file(Value)};
        "client-key" -> {client_key, Value, decode_cert_file(Value)};
        Name -> {name_to_atom(Name), {ok, Value}}
    end, {ok, Config});

complete_kubeconfig(_Name, _Value, {error, Reason}) -> {error, Reason}.

complete_kubeconfig(Result, {ok, Config}) ->
    case Result of
        {Name, {ok, Data}} -> {ok, maps:put(Name, Data, Config)};
        {Name, _Value, {ok, Data}} -> {ok, maps:put(Name, Data, Config)};
        {Name, {error, Reason}} -> {error, {Name, Reason}};
        {Name, Value, {error, Reason}} -> {error, {Name, Value, Reason}}
    end.

decode_cert_file(FileName) ->
    case file:read_file(FileName) of
        {ok, Binary} -> decode_cert(Binary);
        {error, Reason} -> {error, Reason}
    end.

decode_cert_b64(Base64Encoded) ->
    try base64:decode(Base64Encoded) of
        Value -> decode_cert(Value)
    catch
        _:_ -> {error, invalid_base64}
    end.

decode_cert(Value) ->
    try public_key:pem_decode(Value) of
        [{'Certificate', Cert, not_encrypted}|_] -> {ok, Cert};
        [{Type, Cert, not_encrypted}|_] -> {ok, {Type, Cert}};
        [] -> {error, invalid_pem}
    catch
        _:_ -> {error, invalid_pem}
    end.

name_to_atom(Name) ->
    list_to_atom(lists:flatten(string:replace(Name, "-", "_", all))).

trim_suffix(Name) ->
    "elif_" ++ NewName = lists:reverse(atom_to_list(Name)),
    list_to_atom(lists:reverse(NewName)).
