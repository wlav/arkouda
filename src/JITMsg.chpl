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

        #include "JITCWrapper.h"

        typedef double (*disp_1d_t)(double);

        int dispIsValid(gen_disp_t fdisp);
        double callDisp1D(gen_disp_t, double);

        int dispIsValid(gen_disp_t fdisp) {
            return (int)(fdisp != (gen_disp_t)0);
        }

        double callDisp1D(gen_disp_t fdisp, double d) {
            return ((disp_1d_t)fdisp)(d);
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

            var arr: borrowed GenSymEntry = getGenericTypedArrayEntry(arr_name, st);
            select (arr.dtype) {
                when (DType.Float64) {
                    var l = toSymEntry(arr, real, nd);
                    if (inplace) {
                        forall a in l.a do
                            a = callDisp1D(fdisp, a);
                        repMsg = "success";
                    } else {
                        var rname = st.nextName();
                        var e = st.addEntry(rname, l.tupShape, real);
                        e.a = forall a in l.a do
                                  callDisp1D(fdisp, a);
                        repMsg = "created %s".format(st.attrib(rname));
                    }
                }
            }

            JITMsg_ClearMainDyLib();
            return new MsgTuple(repMsg, MsgType.NORMAL);
        }

        return new MsgTuple("Unknown JIT request", MsgType.ERROR);
    }

}
