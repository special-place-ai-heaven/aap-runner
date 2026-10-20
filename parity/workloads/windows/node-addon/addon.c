/* Minimal Node-API addon. The few Node-API declarations it needs are written out here (same signatures as
   node_api.h) so the build needs no header download; node.def turns them into an import library for node.exe. */
#include <stddef.h>
#include <stdint.h>

typedef struct napi_env__ *napi_env;
typedef struct napi_value__ *napi_value;
typedef struct napi_callback_info__ *napi_callback_info;
typedef int napi_status;
typedef napi_value (*napi_callback)(napi_env env, napi_callback_info info);

__declspec(dllimport) napi_status napi_create_string_utf8(napi_env env, const char *str, size_t length, napi_value *result);
__declspec(dllimport) napi_status napi_create_function(napi_env env, const char *utf8name, size_t length, napi_callback cb,
                                                       void *data, napi_value *result);
__declspec(dllimport) napi_status napi_set_named_property(napi_env env, napi_value object, const char *utf8name, napi_value value);

static napi_value hello(napi_env env, napi_callback_info info)
{
    napi_value s;
    (void)info;
    napi_create_string_utf8(env, "hello from a node-api addon", SIZE_MAX, &s);
    return s;
}

__declspec(dllexport) napi_value napi_register_module_v1(napi_env env, napi_value exports)
{
    napi_value fn;
    napi_create_function(env, "hello", SIZE_MAX, hello, NULL, &fn);
    napi_set_named_property(env, exports, "hello", fn);
    return exports;
}

__declspec(dllexport) int32_t node_api_module_get_api_version_v1(void)
{
    return 8;
}
