#define PY_SSIZE_T_CLEAN
#include <Python.h>

static PyObject *add(PyObject *self, PyObject *args)
{
    long a, b;
    (void)self;
    if (!PyArg_ParseTuple(args, "ll", &a, &b))
        return NULL;
    return PyLong_FromLong(a + b);
}

static PyMethodDef methods[] = {
    {"add", add, METH_VARARGS, "Add two integers."},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef module = {PyModuleDef_HEAD_INIT, "parity_ext", NULL, -1, methods};

PyMODINIT_FUNC PyInit_parity_ext(void)
{
    return PyModule_Create(&module);
}
