/* Minimal Node-API addon built against the node_api.h that ships with the installed Node.js. */
#include <node_api.h>

static napi_value hello(napi_env env, napi_callback_info info)
{
    napi_value s;
    (void)info;
    napi_create_string_utf8(env, "hello from a node-api addon", NAPI_AUTO_LENGTH, &s);
    return s;
}

static napi_value init(napi_env env, napi_value exports)
{
    napi_value fn;
    napi_create_function(env, "hello", NAPI_AUTO_LENGTH, hello, NULL, &fn);
    napi_set_named_property(env, exports, "hello", fn);
    return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
