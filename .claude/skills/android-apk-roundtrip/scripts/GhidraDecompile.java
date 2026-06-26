// Ghidra headless post-script: decompile functions of a native .so to C.
//
// Usage (the .so is imported by analyzeHeadless; this runs after auto-analysis):
//   analyzeHeadless <projDir> proj -import libfoo.so \
//     -scriptPath <this dir> -postScript GhidraDecompile.java -deleteProject
//
// Controlled by env vars:
//   GHIDRA_OUT    output .c path           (default /tmp/ghidra-decompiled.c)
//   GHIDRA_FUNCS  comma-separated filters  (substring of a function name, or 0x<addr>);
//                 empty/unset = decompile every function.
//
// Java GhidraScript (works in headless without PyGhidra). The public class name MUST
// match the file name: GhidraDecompile.java.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.util.task.ConsoleTaskMonitor;
import java.io.FileWriter;
import java.io.PrintWriter;

public class GhidraDecompile extends GhidraScript {
    @Override
    public void run() throws Exception {
        String out = System.getenv("GHIDRA_OUT");
        if (out == null || out.isEmpty()) out = "/tmp/ghidra-decompiled.c";
        String fenv = System.getenv("GHIDRA_FUNCS");
        String[] filters = (fenv == null || fenv.isEmpty()) ? new String[0] : fenv.split(",");

        DecompInterface dec = new DecompInterface();
        dec.openProgram(currentProgram);
        ConsoleTaskMonitor monitor = new ConsoleTaskMonitor();
        FunctionManager fm = currentProgram.getFunctionManager();

        PrintWriter w = new PrintWriter(new FileWriter(out));
        w.println("// Ghidra decompilation of " + currentProgram.getName());
        w.println();
        int count = 0;
        for (Function fn : fm.getFunctions(true)) {
            String name = fn.getName();
            String addr = "0x" + Long.toHexString(fn.getEntryPoint().getOffset());
            boolean want = filters.length == 0;
            for (String f : filters) {
                f = f.trim();
                if (!f.isEmpty() && (f.equals(addr) || name.contains(f))) { want = true; break; }
            }
            if (!want) continue;
            DecompileResults res = dec.decompileFunction(fn, 90, monitor);
            if (res != null && res.getDecompiledFunction() != null) {
                w.println("// " + name + " @ " + addr);
                w.println(res.getDecompiledFunction().getC());
                w.println();
                count++;
            }
        }
        w.close();
        println("ghidra-decompile: wrote " + count + " function(s) to " + out);
    }
}
