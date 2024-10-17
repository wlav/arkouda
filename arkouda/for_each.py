import arkouda as ak
import arkouda.dispatch_utils

__all__ = ['for_each']


def for_each(pda_in, functor, inplace=False):
    sfunc = ak.dispatch_utils.ir_compile("{0}({0})".format(pda_in.dtype))(functor)

    server_msg = ak.client.generic_msg(
        "jit1D",
        {"request":  "run1D",
         "fname":    sfunc._wrapper_name,
         "func_ir":  sfunc.inspect_llvm(),
         "arr_name": pda_in,
         "inplace":  inplace})

    if not inplace:
        return ak.create_pdarray(server_msg)

    return pda_in
