// Small Win32 bridge for PowerShell maintenance, not an additional service.
// Windows 10+: JOB_LIST joins the named job atomically with process creation.
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace AgentOS.Maintenance {
    public static class WindowsJob {
        [StructLayout(LayoutKind.Sequential)] struct SA { public int length; public IntPtr descriptor; public int inherit; }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct SI {
            public int size; public string reserved, desktop, title;
            public int x, y, width, height, xChars, yChars, fill, flags;
            public short show, reservedSize; public IntPtr reservedPointer, input, output, error;
        }
        [StructLayout(LayoutKind.Sequential)] struct SIX { public SI startup; public IntPtr attributes; }
        [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr process, thread; public uint pid, tid; }
        [StructLayout(LayoutKind.Sequential)] struct BasicLimits { public long processTime, jobTime; public uint flags; public UIntPtr minWorkingSet, maxWorkingSet; public uint activeProcesses; public UIntPtr affinity; public uint priority, scheduling; }
        [StructLayout(LayoutKind.Sequential)] struct IOCounts { public ulong readOps, writeOps, otherOps, readBytes, writeBytes, otherBytes; }
        [StructLayout(LayoutKind.Sequential)] struct Limits { public BasicLimits basic; public IOCounts io; public UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory; }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObjectW(ref SA sa, string name);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int info, IntPtr buffer, uint size, out uint returned);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int info, ref Limits buffer, uint size);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool DuplicateHandle(IntPtr sourceProcess, IntPtr source, IntPtr targetProcess, out IntPtr target, uint access, bool inherit, uint options);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr handle);
        [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CommandLineToArgvW(string command, out int count);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl, uint revision, out IntPtr descriptor, out uint size);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string name, uint access, uint sharing, ref SA sa, uint creation, uint attributes, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, uint flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref SIX startup, out PI info);
        static void Check(bool ok, string operation) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed"); }
        public static string[] Arguments(string command) {
            IntPtr args=CommandLineToArgvW(command,out int count); Check(args!=IntPtr.Zero,"Parse process identity");
            try { var result=new string[count]; for(int i=0;i<count;i++) result[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(args,i*IntPtr.Size)); return result; }
            finally { LocalFree(args); }
        }
        static IntPtr Open(string name) {
            IntPtr job = OpenJobObjectW(0x0004 | 0x0008 | 0x0001, false, name); // QUERY | TERMINATE | ASSIGN
            if (job == IntPtr.Zero && Marshal.GetLastWin32Error() != 2) Check(false, "Open owned job");
            return job;
        }
        static IntPtr Create(string name, string owner) {
            IntPtr descriptor;
            Check(ConvertStringSecurityDescriptorToSecurityDescriptorW("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;" + owner + ")", 1, out descriptor, out _), "Job security");
            try {
                var sa = new SA { length=Marshal.SizeOf<SA>(), descriptor=descriptor };
                IntPtr job = CreateJobObjectW(ref sa, name); int error = Marshal.GetLastWin32Error();
                if (job == IntPtr.Zero) throw new Win32Exception(error, "Create owned job failed");
                if (error == 183) { CloseHandle(job); throw new InvalidOperationException("Job identity already exists"); }
                return job;
            } finally { LocalFree(descriptor); }
        }
        static uint[] Members(IntPtr job) {
            for (int capacity=16; capacity<=65536; capacity*=2) {
                int size=8+IntPtr.Size*capacity; IntPtr buffer=Marshal.AllocHGlobal(size);
                try {
                    bool ok=QueryInformationJobObject(job, 3, buffer, (uint)size, out _);
                    if (!ok && Marshal.GetLastWin32Error()==234) continue;
                    Check(ok, "Query owned job");
                    int count=Marshal.ReadInt32(buffer, 4);
                    if (count<0 || count>capacity) throw new InvalidOperationException("Invalid job membership");
                    uint[] result=new uint[count];
                    for(int i=0;i<count;i++) result[i]=checked((uint)Marshal.ReadIntPtr(buffer, 8+i*IntPtr.Size).ToInt64());
                    return result;
                } finally { Marshal.FreeHGlobal(buffer); }
            }
            throw new InvalidOperationException("Job membership exceeds safety bound");
        }
        public static uint[] Members(string name) {
            IntPtr job=Open(name); if(job==IntPtr.Zero) return Array.Empty<uint>();
            try { return Members(job); } finally { CloseHandle(job); }
        }
        public static void Stop(string name) {
            IntPtr job=Open(name); if(job==IntPtr.Zero) return;
            try {
                Check(TerminateJobObject(job, 1), "Terminate owned job");
                for(int i=0;i<100;i++) { if(Members(job).Length==0) return; System.Threading.Thread.Sleep(100); }
                throw new InvalidOperationException("Owned job has not stopped; retain its journal");
            } finally { CloseHandle(job); }
        }
        public static uint Start(string binary, string config, string directory, string jobName, string owner, string environment, string stdout, string stderr, Action onCreated) {
            IntPtr job=Create(jobName,owner), attrs=IntPtr.Zero, jobs=IntPtr.Zero, handles=IntPtr.Zero, env=IntPtr.Zero;
            IntPtr output=IntPtr.Zero,error=IntPtr.Zero,input=IntPtr.Zero,keepAlive=IntPtr.Zero; bool initialized=false;
            try {
                // No process may enter this job before its successful creation
                // has been journaled. An existing-name refusal must never cause
                // catch/recovery to terminate someone else's job.
                onCreated();
                var limits=new Limits { basic=new BasicLimits { flags=0x2000 } }; // KILL_ON_JOB_CLOSE
                Check(SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf<Limits>()),"Job exit policy");
                // Merely keeping a process in a job does NOT retain its name
                // after the last handle closes. The root inherits a QUERY-only
                // handle, so the launcher can exit and later reopen by name.
                // After the root and any temporary maintenance handles close,
                // Windows kills even a Node busy-loop ignoring stdin.
                Check(DuplicateHandle(GetCurrentProcess(),job,GetCurrentProcess(),out keepAlive,4,true,0),"Job keepalive handle");
                var sa=new SA { length=Marshal.SizeOf<SA>(), inherit=1 };
                output=CreateFileW(stdout,0x40000000,3,ref sa,1,0x80,IntPtr.Zero); Check(output!=new IntPtr(-1),"Create stdout");
                error=CreateFileW(stderr,0x40000000,3,ref sa,1,0x80,IntPtr.Zero); Check(error!=new IntPtr(-1),"Create stderr");
                input=CreateFileW("NUL",0x80000000,3,ref sa,3,0,IntPtr.Zero); Check(input!=new IntPtr(-1),"Open stdin");
                IntPtr size=IntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero,2,0,ref size);
                attrs=Marshal.AllocHGlobal(size); Check(InitializeProcThreadAttributeList(attrs,2,0,ref size),"Initialize launch attributes"); initialized=true;
                jobs=Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(jobs,job);
                Check(UpdateProcThreadAttribute(attrs,0,new IntPtr(0x2000D),jobs,new IntPtr(IntPtr.Size),IntPtr.Zero,IntPtr.Zero),"Atomic job assignment");
                handles=Marshal.AllocHGlobal(IntPtr.Size*4);
                Marshal.WriteIntPtr(handles,0,input); Marshal.WriteIntPtr(handles,IntPtr.Size,output); Marshal.WriteIntPtr(handles,IntPtr.Size*2,error);
                Marshal.WriteIntPtr(handles,IntPtr.Size*3,keepAlive);
                Check(UpdateProcThreadAttribute(attrs,0,new IntPtr(0x20002),handles,new IntPtr(IntPtr.Size*4),IntPtr.Zero,IntPtr.Zero),"Restrict inherited handles");
                env=Marshal.StringToHGlobalUni(environment);
                var si=new SIX { startup=new SI { size=Marshal.SizeOf<SIX>(), flags=0x101, input=input, output=output, error=error }, attributes=attrs };
                // Paths cannot contain quotes; only a config path is exposed on the command line.
                var command=new StringBuilder("\""+binary+"\" --config \""+config+"\"");
                Check(CreateProcessW(binary,command,IntPtr.Zero,IntPtr.Zero,true,0x08080400,env,directory,ref si,out PI pi),"Create managed process");
                try { return pi.pid; } finally { CloseHandle(pi.thread); CloseHandle(pi.process); }
            } finally {
                if(initialized) DeleteProcThreadAttributeList(attrs);
                foreach(IntPtr p in new[]{attrs,jobs,handles,env}) if(p!=IntPtr.Zero) Marshal.FreeHGlobal(p);
                foreach(IntPtr h in new[]{input,output,error,keepAlive,job}) if(h!=IntPtr.Zero && h!=new IntPtr(-1)) CloseHandle(h);
            }
        }
    }
}
