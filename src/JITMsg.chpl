module JITMsg
{
    use ServerConfig;

    use Reflection;
    use ServerErrors;
    use Logging;
    use Message;
    use MultiTypeSymbolTable;
    use MultiTypeSymEntry;
    use ServerErrorStrings;

    use Map;

    private config const logLevel = ServerConfig.logLevel;
    private config const logChannel = ServerConfig.logChannel;
    const sLogger = new Logger(logLevel, logChannel);

    extern {

        #include <stdint.h>
        #include "JITCWrapper.h"

        typedef int64_t (*disp_1d_i64_t)(int64_t);
        typedef double (*disp_1d_f64_t)(double);

        int dispIsValid(gen_disp_t fdisp);
        int64_t callDisp1D_i64(gen_disp_t, int64_t);
        double callDisp1D_f64(gen_disp_t, double);

        int dispIsValid(gen_disp_t fdisp) {
            return (int)(fdisp != (gen_disp_t)0);
        }

        int64_t callDisp1D_i64(gen_disp_t fdisp, int64_t i) {
            return ((disp_1d_i64_t)fdisp)(i);
        }

        double callDisp1D_f64(gen_disp_t fdisp, double d) {
            return ((disp_1d_f64_t)fdisp)(d);
        }
    }

    var initOK: bool = JITMsg_initializeLLVMJIT() == 0;

    @arkouda.registerND
    proc jitMsg(cmd: string, msgArgs: borrowed MessageArgs, st: borrowed SymTab, param nd: int): MsgTuple throws {
        if (!initOK) {
            return new MsgTuple("failed to initialize the JIT", MsgType.ERROR);
        }

        const request = msgArgs.getValueOf("request");

        if (request == "host") {
            var host = string.createCopyingBuffer(JITMsg_getHost());
            return new MsgTuple(host, MsgType.NORMAL);
        }

        if (request == "triple") {
            var triple = string.createCopyingBuffer(JITMsg_getTargetTriple());
            return new MsgTuple(triple, MsgType.NORMAL);
        }

        if (request == "layout") {
            var layout = string.createCopyingBuffer(JITMsg_getDataLayout());
            return new MsgTuple(layout, MsgType.NORMAL);
        }

        if (request == "cpu_features") {
            var cpu_features = string.createCopyingBuffer(JITMsg_getCPUFeatures());
            return new MsgTuple(cpu_features, MsgType.NORMAL);
        }

        if (request == "run1D") {
            const arr_name = msgArgs.getValueOf("arr_name");
            const fname    = msgArgs.getValueOf("fname");
            const func_ir  = msgArgs.getValueOf("func_ir");
            const inplace: bool = msgArgs.get("inplace").getBoolValue();

            var fdisp = JITMsg_Compile(fname.c_str(), func_ir.c_str());

            if (!dispIsValid(fdisp)) {
                return new MsgTuple("failed to compile function IR", MsgType.ERROR);
            }

            var repMsg: string;
            var typMsg = MsgType.NORMAL;

            var arr: borrowed GenSymEntry = getGenericTypedArrayEntry(arr_name, st);
            select (arr.dtype) {
                when (DType.Float64) {
                    var l = toSymEntry(arr, real, nd);
                    if (inplace) {
                        forall a in l.a do
                            a = callDisp1D_f64(fdisp, a);
                        repMsg = "success";
                    } else {
                        var rname = st.nextName();
                        var e = st.addEntry(rname, l.tupShape, real);
                        e.a = forall a in l.a do
                                  callDisp1D_f64(fdisp, a);
                        repMsg = "created %s".format(st.attrib(rname));
                    }
                }
                when (DType.Int64) {
                    var l = toSymEntry(arr, int, nd);
                    if (inplace) {
                        forall a in l.a do
                            a = callDisp1D_i64(fdisp, a);
                        repMsg = "success";
                    } else {
                        var rname = st.nextName();
                        var e = st.addEntry(rname, l.tupShape, int);
                        e.a = forall a in l.a do
                                  callDisp1D_i64(fdisp, a);
                        repMsg = "created %s".format(st.attrib(rname));
                    }
                }
                otherwise {
                    repMsg = "Unsupported array data type";
                    typMsg = MsgType.ERROR;
                }
            }

            JITMsg_ClearMainDyLib();
            return new MsgTuple(repMsg, typMsg);
        }

        return new MsgTuple("Unknown JIT request", MsgType.ERROR);
    }

}
