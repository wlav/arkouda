import arkouda as ak

import base64
import pickle

import numba.core.codegen as nb_cg
import numba.core.compiler as nb_cmp
import numba.core.compiler_machinery as nb_cmpm
import numba.core.decorators as nb_dec
import numba.core.cgutils as nb_cgu
import numba.core.registry as nb_reg
import numba.core.targetconfig as nb_tc
import numba.core.tracing as nb_trc
import numba.core.typing as nb_typing

import llvmlite.binding as ll
import llvmlite.ir as llvmir

__all__ = ['ir_compile']


class ServerCPUCodegen(nb_cg.JITCPUCodegen):
    """
    Codegen for cross-compilation to the Arkouda Server CPU

    Numba does not provide for cross-compilation and the CPU target is a global
    object that is accessed throughout the compiled code. This class replaces,
    for the duration of the IR compilation, the global target's JITCPUCodegen,
    to generate IR for the server instead of the client.
    """

    server_host   = None
    server_triple = None
    server_layout = None
    server_cpu_features = None
    common_cpu_features = None

    @staticmethod
    def _server_property(request):
        name = 'server_'+request
        if getattr(ServerCPUCodegen, name) is None:
            value = ak.client.generic_msg("jit1D", {"request": request})
            setattr(ServerCPUCodegen, name, value)
        return getattr(ServerCPUCodegen, name)

    @staticmethod
    def _get_server_host():
        return ServerCPUCodegen._server_property("host")

    @staticmethod
    def _get_server_triple():
        return ServerCPUCodegen._server_property("triple")

    @staticmethod
    def _get_server_layout():
        return ServerCPUCodegen._server_property("layout")

    @staticmethod
    def _get_server_features():
        return ServerCPUCodegen._server_property("cpu_features")

    def __init__(self, *args, **kwds):
        super().__init__(*args, **kwds)

    def _create_empty_module(self, name):
        ir_module = llvmir.Module(nb_cgu.normalize_ir_text(name))
        ir_module.triple = self._get_server_triple()
        ir_module.data_layout = self._get_server_layout()
        return ir_module

    def _get_host_cpu_name(self):
        return ServerCPUCodegen._get_server_host()

    def _get_host_cpu_features(self):
        # there may be differences in LLVM versions between client and server; strip
        # out all server features that are not supported by the client (and would
        # result in a warning when configuring the JIT)
        if ServerCPUCodegen.common_cpu_features is None:
            server_features = ServerCPUCodegen._get_server_features()
            client_features = set([x[1:] for x in super()._get_host_cpu_features().split(',')])

            common_features = list()
            for feature in server_features.split(','):
                if feature[1:] in client_features:
                    common_features.append(feature)

            ServerCPUCodegen.common_cpu_features = ",".join(common_features)
        return ServerCPUCodegen.common_cpu_features

    @property
    def _data_layout(self):   # shadows base class data memember
        return ServerCPUCodegen._get_server_layout()

    @_data_layout.setter
    def _data_layout(self, value):
        pass

    def _add_module(self, module):
        # block adding modules to the client-side JIT
        return

    def set_env(self, env_name, env):
        return


class ServerLLVMTarget:
    """Context for cross-compilation to the Arkouda Server CPU

       Numba does not support cross compilation directly and the use of the
       CPU target and context is global. This context manager modifies the
       the triple and data layout for its duration to the ones of the Arkouda
       server-side JIT.

       Note: changes are made both in Python (where values are cached) as well
       as in the LLVM JIT as used by Numba.
    """

    @staticmethod
    def _get_process_triple():
        return ServerCPUCodegen.server_triple

    def __init__(self):
        self.orig_ftriple = ll.get_process_triple

        self.cpu_tgt = nb_reg.cpu_target.target_context
        self.orig_cg = self.cpu_tgt._internal_codegen

    def __enter__(self):
        ll.get_process_triple = self._get_process_triple

        self.cpu_tgt._internal_codegen = ServerCPUCodegen("arkouda.server")

    def __exit__(self, exc_type, exc_value, exc_tb):
        ll.get_process_triple = self.orig_ftriple
        self.cpu_tgt._internal_codegen = self.orig_cg


# -- IR compiler ------------------------------------------------------------
class IRCompiler(nb_cmp.CompilerBase):
    """
    IR compiler based on the Numba compilation chain

    Run the default Numba passes up to the point of IR optimization at the
    llvmlite level, to pre-empt target-specific optimization.
    """

    def define_pipelines(self):
        pm = nb_cmp.DefaultPassBuilder.define_nopython_pipeline(self.state)
        pm.finalize()

        return [pm]


# -- decorator to select the IR Compiler ------------------------------------
def ir_compile(*args, **kwds):
    kwds["nopython"] = True
    kwds["pipeline_class"] = IRCompiler
    kwds["_nrt"] = False

    cf = nb_dec.cfunc(*args, **kwds)

    def server_cfunc(*args, **kwds):
        with ServerLLVMTarget():
            return cf(*args, **kwds)

    return server_cfunc

