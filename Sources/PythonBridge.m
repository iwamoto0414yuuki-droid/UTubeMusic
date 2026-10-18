#import "PythonBridge.h"
#include <Python/Python.h>

@implementation MusicPythonBridge
+ (NSString *)call:(NSString *)request resourcePath:(NSString *)path error:(NSError **)error {
    // Called exclusively from PythonService's serial worker, never from the UI thread.
    static BOOL initialized = NO;
    if (!initialized) {
        PyPreConfig preconfig;
        PyPreConfig_InitIsolatedConfig(&preconfig);
        preconfig.utf8_mode = 1;
        PyStatus status = Py_PreInitialize(&preconfig);
        if (!PyStatus_Exception(status)) {
            PyConfig config;
            PyConfig_InitIsolatedConfig(&config);
            config.write_bytecode = 0;
            config.buffered_stdio = 0;
            config.install_signal_handlers = 0;
            NSString *home = [path stringByAppendingPathComponent:@"python"];
            status = PyConfig_SetBytesString(&config, &config.home, home.UTF8String);
            if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
            PyConfig_Clear(&config);
        }
        if (PyStatus_Exception(status)) {
            if (error) *error = [NSError errorWithDomain:@"UTubeMusic.Python" code:1 userInfo:@{NSLocalizedDescriptionKey: @"音声取得エンジンを起動できません。ビルド構成を確認してください。"}];
            return nil;
        }
        PyObject *sysPath = PySys_GetObject("path");
        NSString *appPath = [path stringByAppendingPathComponent:@"app"];
        PyObject *app = PyUnicode_FromString(appPath.UTF8String);
        PyList_Insert(sysPath, 0, app);
        Py_DECREF(app);
        initialized = YES;
        PyEval_SaveThread();
    }
    PyGILState_STATE state = PyGILState_Ensure();
    PyObject *module = PyImport_ImportModule("music_engine");
    PyObject *function = module ? PyObject_GetAttrString(module, "dispatch") : NULL;
    PyObject *argument = PyUnicode_FromString(request.UTF8String);
    PyObject *result = function ? PyObject_CallFunctionObjArgs(function, argument, NULL) : NULL;
    NSString *output = nil;
    if (result) {
        const char *utf8 = PyUnicode_AsUTF8(result);
        if (utf8) output = [NSString stringWithUTF8String:utf8];
    }
    if (!output) {
        PyErr_Print();
        if (error) *error = [NSError errorWithDomain:@"UTubeMusic.Python" code:2 userInfo:@{NSLocalizedDescriptionKey: @"音声取得エンジンの読み込みに失敗しました。"}];
    }
    Py_XDECREF(result); Py_DECREF(argument); Py_XDECREF(function); Py_XDECREF(module);
    PyGILState_Release(state);
    return output;
}
@end
