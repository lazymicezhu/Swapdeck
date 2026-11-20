using System.Runtime.InteropServices;
namespace Swapdeck;

internal static class ThreadOwners
{
    [DllImport("winsqlite3", CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string path,out IntPtr db,int flags,IntPtr vfs);
    [DllImport("winsqlite3", CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_prepare_v2(IntPtr db,[MarshalAs(UnmanagedType.LPUTF8Str)] string sql,int count,out IntPtr statement,IntPtr tail);
    [DllImport("winsqlite3", CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_step(IntPtr statement);
    [DllImport("winsqlite3", CallingConvention=CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_text(IntPtr statement,int column);
    [DllImport("winsqlite3", CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_finalize(IntPtr statement);
    [DllImport("winsqlite3", CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_close(IntPtr db);
    public static Dictionary<string,string> Read(string home)
    {
        var result = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        if (!Directory.Exists(home)) return result;
        var file = Directory.EnumerateFiles(home,"state_*.sqlite").OrderByDescending(f=>int.TryParse(Path.GetFileNameWithoutExtension(f)[6..],out var version)?version:0).FirstOrDefault();
        if (file == null) return result;
        IntPtr db=IntPtr.Zero, statement=IntPtr.Zero;
        try {
            if (sqlite3_open_v2(file,out db,1,IntPtr.Zero)!=0 ||
                sqlite3_prepare_v2(db,"SELECT rollout_path, creator_account_id FROM threads WHERE creator_account_id IS NOT NULL",-1,out statement,IntPtr.Zero)!=0) return result;
            while(sqlite3_step(statement)==100){
                var path=Marshal.PtrToStringUTF8(sqlite3_column_text(statement,0));
                var account=Marshal.PtrToStringUTF8(sqlite3_column_text(statement,1));
                if(path!=null && account!=null) result[Path.GetFileName(path)]=account;
            }
        } finally {if(statement!=IntPtr.Zero) sqlite3_finalize(statement); if(db!=IntPtr.Zero) sqlite3_close(db);}
        return result;
    }
}