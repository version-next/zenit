# Owned E2E platform queries and input. Desktop input requires foreground opt-in.
function Initialize-WindowsNativeInput {
  if ('ZenitNativeInput' -as [type]) { return }
  Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.IO;
using System.Windows.Forms;
public static class ZenitNativeInput {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] struct Keyboard { public ushort VK, Scan; public uint Flags, Time; public IntPtr Extra; }
  [StructLayout(LayoutKind.Sequential)] struct Mouse { public int X,Y; public uint Data,Flags,Time; public IntPtr Extra; }
  [StructLayout(LayoutKind.Explicit, Size=32)] struct Union { [FieldOffset(0)] public Keyboard Key; [FieldOffset(0)] public Mouse Mouse; }
  [StructLayout(LayoutKind.Sequential)] struct Input { public uint Type; public Union Data; }
  [DllImport("user32.dll")] static extern uint SendInput(uint n, Input[] inputs, int size);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hwnd);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd,uint message,IntPtr wparam,IntPtr lparam);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd,uint message,IntPtr wparam,IntPtr lparam);
  public static void CloseOwned(IntPtr hwnd,int process){if(!Owned(hwnd,process)||GetForegroundWindow()!=hwnd||!PostMessage(hwnd,0x10,IntPtr.Zero,IntPtr.Zero))throw new InvalidOperationException("Owned close rejected");}
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("dwmapi.dll")] public static extern int DwmFlush();
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd,int attribute,out Rect rect,int size);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out Point point);
  [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd, ref Point point);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd,StringBuilder text,int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd,StringBuilder text,int count);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd,uint command);
  public static bool Owned(IntPtr hwnd,int process) { uint pid;GetWindowThreadProcessId(hwnd,out pid);return hwnd!=IntPtr.Zero && pid==process; }
  delegate bool EnumWindowProc(IntPtr hwnd,IntPtr param);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowProc callback,IntPtr param);
  public static IntPtr AppWindow(int process) {
    IntPtr found=IntPtr.Zero;int count=0;
    // Owned panels (a find or palette window) are not the app window: count
    // only windows without an owner (GW_OWNER = 4).
    EnumWindows(delegate(IntPtr hwnd,IntPtr ignored){if(Owned(hwnd,process)&&Class(hwnd)=="ZenitWindow"&&GetWindow(hwnd,4)==IntPtr.Zero){found=hwnd;count++;}return true;},IntPtr.Zero);
    if(count!=1)throw new InvalidOperationException("Expected one owned ZenitWindow, found "+count);
    return found;
  }
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
  // Status may inspect several owned app windows; input retains AppWindow's
  // single-window guard. Prefer the real foreground app window, never guess.
  public static IntPtr StatusWindow(int process) {
    IntPtr foreground=GetForegroundWindow();
    if(Owned(foreground,process)&&Class(foreground)=="ZenitWindow"&&GetWindow(foreground,4)==IntPtr.Zero)return foreground;
    return AppWindow(process);
  }
  public static System.Collections.Hashtable[] WindowInventory(int process) {
    var rows=new System.Collections.Generic.List<System.Collections.Hashtable>();
    EnumWindows(delegate(IntPtr hwnd,IntPtr ignored){
      if(Owned(hwnd,process)&&Class(hwnd)=="ZenitWindow"&&GetWindow(hwnd,4)==IntPtr.Zero)
        rows.Add(new System.Collections.Hashtable{{"hwnd",hwnd.ToInt64()},{"visible",IsWindowVisible(hwnd)},{"minimized",IsIconic(hwnd)}});
      return true;
    },IntPtr.Zero);
    return rows.ToArray();
  }
  public static string Title(IntPtr hwnd) { var s=new StringBuilder(512);GetWindowText(hwnd,s,s.Capacity);return s.ToString(); }
  public static string Class(IntPtr hwnd) { var s=new StringBuilder(128);GetClassName(hwnd,s,s.Capacity);return s.ToString(); }
  [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
  [DllImport("imm32.dll")] static extern IntPtr ImmGetContext(IntPtr hwnd);
  [DllImport("imm32.dll")] static extern bool ImmReleaseContext(IntPtr hwnd, IntPtr context);
  [DllImport("imm32.dll")] static extern bool ImmGetOpenStatus(IntPtr context);
  [DllImport("imm32.dll")] static extern bool ImmGetConversionStatus(IntPtr context, out uint conversion, out uint sentence);
  public static string Layout(IntPtr hwnd) { uint pid; return GetKeyboardLayout(GetWindowThreadProcessId(hwnd,out pid)).ToInt64().ToString("x"); }
  public static int Conversion(IntPtr hwnd) {
    IntPtr context=ImmGetContext(hwnd); if(context==IntPtr.Zero)return -1;
    try { uint conversion,sentence;return ImmGetConversionStatus(context,out conversion,out sentence)?(int)conversion:-1; }
    finally { ImmReleaseContext(hwnd,context); }
  }
  public static int Open(IntPtr hwnd) {
    IntPtr context=ImmGetContext(hwnd);if(context==IntPtr.Zero)return -1;
    try{return ImmGetOpenStatus(context)?1:0;}finally{ImmReleaseContext(hwnd,context);}
  }
  [DllImport("user32.dll")] static extern uint MapVirtualKeyEx(uint code,uint mapType,IntPtr layout);
  // Scan code under the foreground thread's keyboard layout (the worker
  // thread's own layout may differ from the app's).
  static uint ScanOf(int vk) {
    uint thread=0;IntPtr fg=GetForegroundWindow();
    if(fg!=IntPtr.Zero)GetWindowThreadProcessId(fg,out thread);
    return MapVirtualKeyEx((uint)vk,0,GetKeyboardLayout(thread))&0xFF;
  }
  // Navigation/edit keys, right-hand modifiers, numpad divide/enter and
  // NumLock are extended keys (E0 prefix) on real keyboards.
  static readonly int[] extendedKeys={0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28,0x2C,0x2D,0x2E,0x5B,0x5C,0x5D,0x6F,0x90,0xA3,0xA5};
  // Inject like the physical key: VK plus its scan code and the extended
  // flag. With scan 0 and no extended flag, VK_RIGHT/VK_END/... are the
  // numpad variants, and with NumLock on the system drops a held Shift
  // for them (the keyboard "fake shift"): Shift+Right moved the caret
  // without selecting on a real Win10 machine while the VM (NumLock off)
  // passed. Ctrl chords were unaffected.
  public static bool Key(int vk,bool up) {
    if(vk<1 || vk>254)throw new ArgumentException("virtual key range");
    Input input=new Input();input.Type=1;input.Data.Key.VK=(ushort)vk;input.Data.Key.Scan=(ushort)ScanOf(vk);
    input.Data.Key.Flags=(up?2u:0u)|(Array.IndexOf(extendedKeys,vk)>=0?1u:0u);
    return SendInput(1,new Input[]{input},Marshal.SizeOf(typeof(Input)))==1;
  }
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd,int command);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd,IntPtr after,int x,int y,int w,int h,uint flags);
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd,uint flags);
  [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
  [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
  [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd,out Rect rect);
  [DllImport("ole32.dll")] static extern int OleInitialize(IntPtr reserved);
  [DllImport("ole32.dll")] static extern void OleUninitialize();
  static IntPtr dragSourceWindow;
  static int dragOwner;
  public static bool SourceForeground(int process) { return dragOwner==process && dragSourceWindow!=IntPtr.Zero && GetForegroundWindow()==dragSourceWindow && Owned(dragSourceWindow,System.Diagnostics.Process.GetCurrentProcess().Id); }
  [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="CreateWindowExW")] static extern IntPtr CreateWindowEx(uint ex,string cls,string title,uint style,int x,int y,int w,int h,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr param);
  [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
  [ComVisible(true),Guid("00000121-0000-0000-C000-000000000046"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IOleSource { [PreserveSig] int QueryContinueDrag([MarshalAs(UnmanagedType.Bool)] bool escape,uint keys); [PreserveSig] int GiveFeedback(uint effect); }
  [ComVisible(true),ClassInterface(ClassInterfaceType.None)]
  public class OleSource : IOleSource {
    int process;public OleSource(int process){this.process=process;}
    public int QueryContinueDrag(bool escape,uint keys) {
      dragDiagnostic="query:keys="+keys+",physical="+GetAsyncKeyState(1)+",held="+mouseHeld+",cancel="+dragCancel+",sourceFore="+SourceForeground(process);
      if(dragCancel||escape||(!Owned(GetForegroundWindow(),process)&&!SourceForeground(process)))return 0x40101;
      return mouseHeld&&GetAsyncKeyState(1)<0?0:0x40100;
    }
    public int GiveFeedback(uint effect){return 0x40102;}
  }
  [DllImport("ole32.dll")] static extern int DoDragDrop([MarshalAs(UnmanagedType.Interface)] System.Runtime.InteropServices.ComTypes.IDataObject data,IOleSource source,uint allowed,out uint effect);
  static Thread dragThread;
  static volatile bool dragActive,dragDone,dragCancel,mouseHeld;
  static volatile int dragEffect;
  static volatile string dragError="", dragDiagnostic="";
  static bool MouseEdge(bool up) {
    Input i=new Input();i.Type=0;i.Data.Mouse.Flags=up?4u:2u;
    return SendInput(1,new Input[]{i},Marshal.SizeOf(typeof(Input)))==1;
  }
  public static void ActivateOwned(IntPtr hwnd,int process) {
    if(!Owned(hwnd,process))throw new InvalidOperationException("Activation target is not owned");
    if(SetForegroundWindow(hwnd)||GetForegroundWindow()==hwnd)return;
    if(mouseHeld||GetAsyncKeyState(1)<0)throw new InvalidOperationException("Activation pointer is already held");
    IntPtr old=SetThreadDpiAwarenessContext(new IntPtr(-4));
    Point saved=new Point();bool moved=false,down=false;
    try {
      // Windows may deny programmatic activation. An attended click on an
      // exposed, owned caption is a real activation gesture, not a key-state
      // workaround. Never click through another process's window.
      Rect outer;
      if(!SetWindowPos(hwnd,IntPtr.Zero,0,0,0,0,0x13)||!GetWindowRect(hwnd,out outer)||!GetCursorPos(out saved))
        throw new InvalidOperationException("Owned activation bounds unavailable");
      double scale=GetDpiForWindow(hwnd)/96.0;Point point=new Point();bool found=false;
      point.X=outer.Left+(int)Math.Round(40*scale);
      for(int y=10;y<50;y+=2) {
        point.Y=outer.Top+(int)Math.Round(y*scale);
        long packed=(uint)(ushort)point.X|((uint)(ushort)point.Y<<16);
        if(SendMessage(hwnd,0x84,IntPtr.Zero,new IntPtr(packed)).ToInt64()==2&&WindowFromPoint(point)==hwnd){found=true;break;}
      }
      if(!found)throw new InvalidOperationException("No exposed owned caption for attended activation");
      if(!SetCursorPos(point.X,point.Y))throw new InvalidOperationException("Activation cursor movement failed");
      moved=true;Thread.Sleep(50);
      if(WindowFromPoint(point)!=hwnd||!MouseEdge(false))throw new InvalidOperationException("Owned activation click refused");
      down=true;Thread.Sleep(50);
      if(!MouseEdge(true))throw new InvalidOperationException("Activation release failed");
      down=false;
      Thread.Sleep(150); // Let the native caption consume mouse-up before moving away.
      for(int attempt=0;attempt<100&&GetForegroundWindow()!=hwnd;attempt++)Thread.Sleep(20);
      if(GetForegroundWindow()!=hwnd)throw new InvalidOperationException("Owned caption did not activate the App");
    } finally {
      if(down)MouseEdge(true);
      if(moved)SetCursorPos(saved.X,saved.Y);
      SetThreadDpiAwarenessContext(old);
    }
  }
  public static void CaptionToggle(IntPtr hwnd,int process) {
    if(!Owned(hwnd,process)||GetForegroundWindow()!=hwnd||mouseHeld||GetAsyncKeyState(1)<0)
      throw new InvalidOperationException("Caption click needs an idle pointer and the owned foreground window");
    IntPtr old=SetThreadDpiAwarenessContext(new IntPtr(-4));
    Point saved=new Point();bool moved=false,down=false;
    bool wasZoomed=IsZoomed(hwnd);
    try {
      Rect buttons,outer;
      if(DwmGetWindowAttribute(hwnd,5,out buttons,Marshal.SizeOf(typeof(Rect)))<0||
         !GetWindowRect(hwnd,out outer)||!GetCursorPos(out saved)||buttons.Right<=buttons.Left||buttons.Bottom<=buttons.Top)
        throw new InvalidOperationException("Caption bounds unavailable");
      // The middle of the native min/max/close group is maximize/restore.
      int x=outer.Left+(buttons.Left+buttons.Right)/2,y=outer.Top+(buttons.Top+buttons.Bottom)/2;
      long packed=(uint)(ushort)x|((uint)(ushort)y<<16);
      long hit=SendMessage(hwnd,0x84,IntPtr.Zero,new IntPtr(packed)).ToInt64();
      if(hit!=9)throw new InvalidOperationException("Caption center was not HTMAXBUTTON: "+hit+" at "+x+","+y);
      if(!SetCursorPos(x,y))
        throw new InvalidOperationException("Caption cursor movement failed");
      moved=true;Thread.Sleep(50);
      Point exposed=new Point();exposed.X=x;exposed.Y=y;
      if(GetForegroundWindow()!=hwnd||WindowFromPoint(exposed)!=hwnd||!MouseEdge(false))throw new InvalidOperationException("Caption press refused");
      down=true;Thread.Sleep(50);
      if(!MouseEdge(true))throw new InvalidOperationException("Caption release failed");
      down=false;
      // Keep the pointer on the button until the App consumes mouse-up.
      // Restoring it immediately can cancel a queued native caption click.
      for(int attempt=0;attempt<100 && IsZoomed(hwnd)==wasZoomed;attempt++)Thread.Sleep(20);
      if(IsZoomed(hwnd)==wasZoomed)throw new InvalidOperationException("Native caption click did not toggle maximization");
    } finally {
      if(down)MouseEdge(true);
      if(moved)SetCursorPos(saved.X,saved.Y);
      SetThreadDpiAwarenessContext(old);
    }
  }
  public static void DragMove(IntPtr hwnd,int process,double x,double y) {
    if(!Owned(GetForegroundWindow(),process)&&!SourceForeground(process))throw new InvalidOperationException("Drag foreground lost");
    IntPtr old=SetThreadDpiAwarenessContext(new IntPtr(-4));
    try {
      Rect r;if(!GetClientRect(hwnd,out r))throw new InvalidOperationException("Missing client bounds");
      double scale=GetDpiForWindow(hwnd)/96.0;
      if(Double.IsNaN(x)||Double.IsInfinity(x)||Double.IsNaN(y)||Double.IsInfinity(y)||x<0||y<0||x*scale>=r.Right||y*scale>=r.Bottom)throw new ArgumentException("Drag must stay inside owned window");
      Point p=new Point();p.X=(int)Math.Round(x*scale);p.Y=(int)Math.Round(y*scale);
      if(!ClientToScreen(hwnd,ref p)||!SetCursorPos(p.X,p.Y))throw new InvalidOperationException("Drag cursor movement failed");
    } finally {SetThreadDpiAwarenessContext(old);}
  }
  public static void DragStart(IntPtr hwnd,int process,double x,double y,string kind,string text,string[] files,int operations) {
    if(dragThread!=null && dragThread.IsAlive)throw new InvalidOperationException("Drag already running");
    if(operations<0||operations>7||GetAsyncKeyState(1)<0)throw new ArgumentException("Invalid source policy or mouse already held");
    if(kind!="files"&&kind!="text"&&kind!="url"&&kind!="internal")throw new ArgumentException("Unsupported drag source format");
    if(text!=null && text.Length>2100000)throw new ArgumentException("Drag source capacity");
    DragMove(hwnd,process,x,y);
    dragDone=false;dragActive=false;dragCancel=false;dragEffect=0;dragError="";dragDiagnostic="starting";
    dragOwner=process;
    dragThread=new Thread(delegate() {
      bool ole=false;
      try {
        int initialized=OleInitialize(IntPtr.Zero);if(initialized<0)Marshal.ThrowExceptionForHR(initialized);ole=true;
        SetThreadDpiAwarenessContext(new IntPtr(-4));dragDiagnostic="thread:"+Thread.CurrentThread.GetApartmentState()+",button:"+GetAsyncKeyState(1)+",foreground:"+Owned(GetForegroundWindow(),process);
        Rect bounds;GetWindowRect(hwnd,out bounds);
        dragSourceWindow=CreateWindowEx(8,"STATIC","Zenit owned OLE test source",0x10cf0000,bounds.Left+400,bounds.Top+60,180,90,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero);
        if(dragSourceWindow==IntPtr.Zero)throw new InvalidOperationException("Native source creation failed");
        ShowWindow(dragSourceWindow,5);SetWindowPos(dragSourceWindow,new IntPtr(-1),0,0,0,0,0x53);
        SetForegroundWindow(dragSourceWindow);Application.DoEvents();
        if(!Owned(GetForegroundWindow(),process)&&!SourceForeground(process))throw new InvalidOperationException("Foreground lost before source click");
        Rect sourceRect;if(!GetWindowRect(dragSourceWindow,out sourceRect))throw new InvalidOperationException("Source bounds unavailable");
        Point click=new Point();click.X=sourceRect.Left+80;click.Y=sourceRect.Top+50;
        if(GetAncestor(WindowFromPoint(click),2)!=dragSourceWindow||!SetCursorPos(click.X,click.Y))throw new InvalidOperationException("Native source is not visible at its actual physical bounds");
        if(!MouseEdge(false))throw new InvalidOperationException("Owned source mouse down failed");mouseHeld=true;
        Application.DoEvents();Thread.Sleep(50);Application.DoEvents();
        if(!SourceForeground(process))throw new InvalidOperationException("Owned native source activation failed");
          DataObject data=new DataObject();
          if(kind=="files")data.SetData(DataFormats.FileDrop,false,files);
          else if(kind=="text")data.SetData(DataFormats.UnicodeText,false,text);
          else {
            byte[] payload=kind=="url"?Encoding.Unicode.GetBytes(text+"\0"):Encoding.UTF8.GetBytes(text);
            byte[] bytes=payload;
            if(kind=="internal") {bytes=new byte[payload.Length+4];Buffer.BlockCopy(BitConverter.GetBytes(payload.Length),0,bytes,0,4);Buffer.BlockCopy(payload,0,bytes,4,payload.Length);}
            data.SetData(kind=="url"?"UniformResourceLocatorW":"Zenit.Internal.UTF8.v1",false,new MemoryStream(bytes));
          }
          dragActive=true;
          uint finalEffect;
          int result=DoDragDrop((System.Runtime.InteropServices.ComTypes.IDataObject)data,new OleSource(process),(uint)operations,out finalEffect);
          if(result<0)Marshal.ThrowExceptionForHR(result);dragEffect=(int)finalEffect;
          if(SourceForeground(process))SetForegroundWindow(hwnd);
      } catch(Exception e) {dragError=e.GetType().Name+": "+e.Message;}
      finally {if(dragSourceWindow!=IntPtr.Zero)DestroyWindow(dragSourceWindow);if(mouseHeld){MouseEdge(true);mouseHeld=false;}if(SourceForeground(process))SetForegroundWindow(hwnd);dragSourceWindow=IntPtr.Zero;dragOwner=0;if(ole)OleUninitialize();dragActive=false;dragDone=true;}
    });
    dragThread.IsBackground=true;dragThread.SetApartmentState(ApartmentState.STA);dragThread.Start();
  }
  public static void PointerDown(IntPtr hwnd,int process,double x,double y) {
    if(mouseHeld||GetAsyncKeyState(1)<0||GetForegroundWindow()!=hwnd)throw new InvalidOperationException("Pointer already held or owned app not foreground");
    DragMove(hwnd,process,x,y);
    IntPtr old=SetThreadDpiAwarenessContext(new IntPtr(-4));
    try {
      Point point=new Point();point.X=(int)Math.Round(x*GetDpiForWindow(hwnd)/96.0);point.Y=(int)Math.Round(y*GetDpiForWindow(hwnd)/96.0);
      if(!ClientToScreen(hwnd,ref point)||GetAncestor(WindowFromPoint(point),2)!=hwnd)throw new InvalidOperationException("Owned app not at pointer");
      if(!MouseEdge(false))throw new InvalidOperationException("Pointer down failed");mouseHeld=true;
    } finally {SetThreadDpiAwarenessContext(old);}
  }
  public static void DragRelease() {if(!mouseHeld)throw new InvalidOperationException("No owned injected drag");if(!MouseEdge(true))throw new InvalidOperationException("Mouse release failed");mouseHeld=false;}
  public static void DragCancel() {
    dragCancel=true;if(mouseHeld){MouseEdge(true);mouseHeld=false;}
    // QueryContinueDrag checks cancellation before release, preventing a drop.
    if(dragThread!=null && dragThread.IsAlive && !dragThread.Join(2000))throw new InvalidOperationException("OLE source cancellation timed out");
    if(mouseHeld){MouseEdge(true);mouseHeld=false;}
  }
  public static bool DragActive(){return dragActive;}
  public static bool DragDone(){return dragDone;}
  public static int DragEffect(){return dragEffect;}
  public static string DragError(){return dragError;}
  public static string DragDiagnostic(){return dragDiagnostic;}
  [ComVisible(true),Guid("00000122-0000-0000-C000-000000000046"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IOleTarget {
    [PreserveSig] int DragEnter([MarshalAs(UnmanagedType.Interface)] System.Runtime.InteropServices.ComTypes.IDataObject data,uint keys,Point point,ref uint effect);
    [PreserveSig] int DragOver(uint keys,Point point,ref uint effect);
    [PreserveSig] int DragLeave();
    [PreserveSig] int Drop([MarshalAs(UnmanagedType.Interface)] System.Runtime.InteropServices.ComTypes.IDataObject data,uint keys,Point point,ref uint effect);
  }
  [DllImport("ole32.dll")] static extern int RegisterDragDrop(IntPtr hwnd,IOleTarget target);
  [DllImport("ole32.dll")] static extern int RevokeDragDrop(IntPtr hwnd);
  [DllImport("ole32.dll")] static extern void ReleaseStgMedium(ref System.Runtime.InteropServices.ComTypes.STGMEDIUM medium);
  [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags,UIntPtr size);
  [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr handle);
  [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr handle);
  [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr handle);
  [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr handle);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
  [StructLayout(LayoutKind.Sequential)] struct Message {public IntPtr Window;public uint Id;public UIntPtr WParam;public IntPtr LParam;public uint Time;public Point Position;public uint Private;}
  [DllImport("user32.dll")] static extern bool PeekMessage(out Message message,IntPtr window,uint min,uint max,uint remove);
  [DllImport("user32.dll")] static extern bool TranslateMessage(ref Message message);
  [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref Message message);
  static readonly object receiverGate=new object();
  static Thread receiverThread;
  static volatile bool receiverStop,receiverReady;
  static IntPtr receiverWindow;
  static int receiverOwner,receiverDrops,receiverEnters,receiverLeaves,receiverKind,receiverEffect,receiverKeys,receiverPolicy;
  static string receiverError="",receiverHash="";
  static int receiverLength;static bool receiverFilesExist,receiverLogical;
  [ComVisible(true),ClassInterface(ClassInterfaceType.None)]
  public class OleTarget : IOleTarget {
    short format;int kind;
    static System.Runtime.InteropServices.ComTypes.FORMATETC Format(short id){return new System.Runtime.InteropServices.ComTypes.FORMATETC{cfFormat=id,dwAspect=System.Runtime.InteropServices.ComTypes.DVASPECT.DVASPECT_CONTENT,lindex=-1,tymed=System.Runtime.InteropServices.ComTypes.TYMED.TYMED_HGLOBAL};}
    static void WriteEffect(System.Runtime.InteropServices.ComTypes.IDataObject data,string name,uint effect){
      IntPtr handle=GlobalAlloc(2,new UIntPtr(4));if(handle==IntPtr.Zero)throw new OutOfMemoryException();
      IntPtr bytes=GlobalLock(handle);if(bytes==IntPtr.Zero){GlobalFree(handle);throw new OutOfMemoryException();}
      Marshal.WriteInt32(bytes,unchecked((int)effect));GlobalUnlock(handle);
      var f=Format(unchecked((short)RegisterClipboardFormat(name)));
      var medium=new System.Runtime.InteropServices.ComTypes.STGMEDIUM{tymed=System.Runtime.InteropServices.ComTypes.TYMED.TYMED_HGLOBAL,unionmember=handle};
      try{data.SetData(ref f,ref medium,false);}finally{ReleaseStgMedium(ref medium);}
    }
    void Choose(System.Runtime.InteropServices.ComTypes.IDataObject data){
      format=0;kind=0;uint[] formats={15,RegisterClipboardFormat("UniformResourceLocatorW"),RegisterClipboardFormat("Zenit.Internal.UTF8.v1"),13};
      for(int i=0;i<formats.Length;i++){short id=unchecked((short)formats[i]);var f=Format(id);if(data.QueryGetData(ref f)==0){format=id;kind=i==3?2:i==2?3:1;break;}}
    }
    uint Effect(uint choices,uint keys){
      lock(receiverGate){receiverKeys=(int)keys;choices&=(uint)receiverPolicy&7;}
      uint wanted=(keys&12)==12?4u:(keys&4)!=0?2u:(keys&8)!=0?1u:(choices&1)!=0?1u:(choices&2)!=0?2u:4u;
      return format!=0?choices&wanted:0;
    }
    public int DragEnter(System.Runtime.InteropServices.ComTypes.IDataObject data,uint keys,Point point,ref uint effect){try{Choose(data);effect=Effect(effect,keys);lock(receiverGate){receiverEnters++;receiverEffect=(int)effect;}return 0;}catch(Exception e){lock(receiverGate){receiverError=e.ToString();}effect=0;return 0;}}
    public int DragOver(uint keys,Point point,ref uint effect){effect=Effect(effect,keys);lock(receiverGate){receiverEffect=(int)effect;}return 0;}
    public int DragLeave(){format=0;lock(receiverGate){receiverLeaves++;receiverEffect=0;}return 0;}
    public int Drop(System.Runtime.InteropServices.ComTypes.IDataObject data,uint keys,Point point,ref uint effect){
      try{
        Choose(data);effect=Effect(effect,keys);if(effect==0)return 0;
        var f=Format(format);System.Runtime.InteropServices.ComTypes.STGMEDIUM medium;data.GetData(ref f,out medium);
        byte[] bytes;
        try{
          if(medium.tymed!=System.Runtime.InteropServices.ComTypes.TYMED.TYMED_HGLOBAL)throw new InvalidDataException("Receiver expected HGLOBAL");
          ulong size=GlobalSize(medium.unionmember).ToUInt64();if(size==0||size>4*1024*1024)throw new InvalidDataException("Receiver payload size");
          IntPtr from=GlobalLock(medium.unionmember);if(from==IntPtr.Zero)throw new InvalidDataException("Receiver GlobalLock");
          try{bytes=new byte[(int)size];Marshal.Copy(from,bytes,0,bytes.Length);}finally{GlobalUnlock(medium.unionmember);}
        }finally{ReleaseStgMedium(ref medium);}
        string text;bool exists=false;
        if(kind==3){if(bytes.Length<4)throw new InvalidDataException("Internal header");uint n=BitConverter.ToUInt32(bytes,0);if(n>bytes.Length-4)throw new InvalidDataException("Internal length");text=new UTF8Encoding(false,true).GetString(bytes,4,(int)n);}
        else if(unchecked((ushort)format)==15){
          if(bytes.Length<20||BitConverter.ToInt32(bytes,16)==0)throw new InvalidDataException("Unicode DROPFILES expected");
          uint offset=BitConverter.ToUInt32(bytes,0);if(offset<20||offset>=bytes.Length||offset%2!=0||(bytes.Length-offset)%2!=0)throw new InvalidDataException("DROPFILES offset");
          string paths=new UnicodeEncoding(false,false,true).GetString(bytes,(int)offset,bytes.Length-(int)offset);int end=paths.IndexOf("\0\0",StringComparison.Ordinal);if(end<0)throw new InvalidDataException("DROPFILES terminator");
          string[] names=paths.Substring(0,end).Split('\0');exists=names.Length>0;foreach(string name in names)exists&=File.Exists(name);text=String.Join("\n",names);
        }else{if(bytes.Length%2!=0)throw new InvalidDataException("UTF16 size");text=new UnicodeEncoding(false,false,true).GetString(bytes);int end=text.IndexOf('\0');if(end<0)throw new InvalidDataException("UTF16 terminator");text=text.Substring(0,end);}
        byte[] utf8=new UTF8Encoding(false,true).GetBytes(text);string hash;
        using(var sha=System.Security.Cryptography.SHA256.Create())hash=BitConverter.ToString(sha.ComputeHash(utf8)).Replace("-","").ToLowerInvariant();
        if(receiverLogical){WriteEffect(data,"Performed DropEffect",0);WriteEffect(data,"Logical Performed DropEffect",effect);}
        lock(receiverGate){receiverHash=hash;receiverLength=utf8.Length;receiverKind=kind;receiverEffect=(int)effect;receiverFilesExist=exists;receiverDrops++;}
        if(receiverLogical)effect=0; // Shell optimized-transfer completion protocol.
      }catch(Exception e){lock(receiverGate){receiverError=e.ToString();}effect=0;}
      format=0;return 0;
    }
  }
  public static void ReceiverStart(IntPtr app,int process,int policy,bool logical){
    ReceiverStop();if(policy<0||policy>7||GetForegroundWindow()!=app)throw new InvalidOperationException("Receiver policy/foreground");
    IntPtr old=SetThreadDpiAwarenessContext(new IntPtr(-4));Rect bounds;
    try{if(!GetWindowRect(app,out bounds))throw new InvalidOperationException("App bounds unavailable");}finally{SetThreadDpiAwarenessContext(old);}
    lock(receiverGate){receiverOwner=process;receiverStop=false;receiverReady=false;receiverDrops=receiverEnters=receiverLeaves=receiverKind=receiverEffect=receiverLength=receiverKeys=0;receiverError=receiverHash="";receiverPolicy=policy;receiverFilesExist=false;receiverLogical=logical;}
    receiverThread=new Thread(delegate(){bool ole=false,registered=false;IntPtr hwnd=IntPtr.Zero;
      IntPtr dpi=SetThreadDpiAwarenessContext(new IntPtr(-4));
      try{
        int hr=OleInitialize(IntPtr.Zero);if(hr<0)Marshal.ThrowExceptionForHR(hr);ole=true;
        hwnd=CreateWindowEx(0x08000008,"STATIC","Zenit independent OLE receiver",0x00cf0000,bounds.Left+650,bounds.Top+80,300,160,IntPtr.Zero,IntPtr.Zero,Marshal.GetHINSTANCE(typeof(ZenitNativeInput).Module),IntPtr.Zero);
        if(hwnd==IntPtr.Zero)throw new InvalidOperationException("Receiver HWND failed");
        OleTarget target=new OleTarget();hr=RegisterDragDrop(hwnd,target);if(hr<0)Marshal.ThrowExceptionForHR(hr);registered=true;
        ShowWindow(hwnd,4);SetWindowPos(hwnd,new IntPtr(-1),bounds.Left+650,bounds.Top+80,300,160,0x50);
        lock(receiverGate){receiverWindow=hwnd;receiverReady=true;}
        while(!receiverStop){Message message;while(PeekMessage(out message,IntPtr.Zero,0,0,1)){TranslateMessage(ref message);DispatchMessage(ref message);}Thread.Sleep(10);}
        GC.KeepAlive(target);
      }catch(Exception e){lock(receiverGate){receiverError=e.ToString();}}
      finally{if(registered)RevokeDragDrop(hwnd);if(hwnd!=IntPtr.Zero)DestroyWindow(hwnd);if(ole)OleUninitialize();SetThreadDpiAwarenessContext(dpi);lock(receiverGate){receiverWindow=IntPtr.Zero;receiverReady=false;}}
    });receiverThread.IsBackground=true;receiverThread.SetApartmentState(ApartmentState.STA);receiverThread.Start();
  }
  public static void ReceiverStop(){receiverStop=true;if(receiverThread!=null&&receiverThread.IsAlive&&!receiverThread.Join(2000))throw new InvalidOperationException("Owned receiver stop timed out");}
  public static void ReceiverActivate(IntPtr app,int process){
    lock(receiverGate){
      if(GetForegroundWindow()!=app||!Owned(app,process)||!receiverReady||receiverOwner!=process||!Owned(receiverWindow,System.Diagnostics.Process.GetCurrentProcess().Id))throw new InvalidOperationException("Receiver activation ownership/foreground");
      if(!SetForegroundWindow(receiverWindow))throw new InvalidOperationException("Owned receiver activation rejected");
    }
  }
  public static void ReceiverMove(IntPtr app,int process){
    if(!Owned(GetForegroundWindow(),process))throw new InvalidOperationException("Receiver motion requires owned App foreground");
    IntPtr old=SetThreadDpiAwarenessContext(new IntPtr(-4));
    try{lock(receiverGate){if(!receiverReady||receiverOwner!=process||receiverWindow==IntPtr.Zero||!Owned(receiverWindow,System.Diagnostics.Process.GetCurrentProcess().Id))throw new InvalidOperationException("Receiver unavailable");
      Rect bounds;GetClientRect(receiverWindow,out bounds);Point point=new Point();point.X=bounds.Right/2;point.Y=bounds.Bottom/2;
      if(!ClientToScreen(receiverWindow,ref point)||GetAncestor(WindowFromPoint(point),2)!=receiverWindow||!SetCursorPos(point.X,point.Y))throw new InvalidOperationException("Owned receiver not at pointer");}}
    finally{SetThreadDpiAwarenessContext(old);}
  }
  // Hover liveness (e2e/windows-hover-native.test.ts): real cursor/wheel input over the owned App
  // while it is foreground OR while the owned receiver (another process's window) is foreground,
  // which makes the App an inactive window. Never targets any other window.
  static void HoverGuard(IntPtr app,int process){
    IntPtr fg=GetForegroundWindow();
    bool receiverFg;lock(receiverGate){receiverFg=receiverReady&&receiverOwner==process&&fg==receiverWindow&&Owned(receiverWindow,System.Diagnostics.Process.GetCurrentProcess().Id);}
    if(!Owned(app,process)||!(Owned(fg,process)||receiverFg))throw new InvalidOperationException("Hover input requires the owned App or owned receiver in the foreground");
  }
  static Point HoverClientPoint(IntPtr app,double x,double y){
    Rect r;if(!GetClientRect(app,out r))throw new InvalidOperationException("Missing client bounds");
    double scale=GetDpiForWindow(app)/96.0;
    if(Double.IsNaN(x)||Double.IsInfinity(x)||Double.IsNaN(y)||Double.IsInfinity(y)||x<0||y<0||x*scale>=r.Right||y*scale>=r.Bottom)throw new ArgumentException("Hover point must be inside the owned App");
    Point p=new Point();p.X=(int)Math.Round(x*scale);p.Y=(int)Math.Round(y*scale);
    if(!ClientToScreen(app,ref p))throw new InvalidOperationException("ClientToScreen failed");
    return p;
  }
  public static void HoverPointerAt(IntPtr app,int process,double x,double y){
    HoverGuard(app,process);IntPtr old=SetThreadDpiAwarenessContext(new IntPtr(-4));
    try{Point p=HoverClientPoint(app,x,y);if(!SetCursorPos(p.X,p.Y))throw new InvalidOperationException("Hover cursor movement failed");}
    finally{SetThreadDpiAwarenessContext(old);}
  }
  public static void HoverWheel(IntPtr app,int process,int delta){
    HoverGuard(app,process);IntPtr old=SetThreadDpiAwarenessContext(new IntPtr(-4));
    try{
      Point c;if(!GetCursorPos(out c)||GetAncestor(WindowFromPoint(c),2)!=app)throw new InvalidOperationException("Wheel target under the cursor is not the owned App");
      Input i=new Input();i.Type=0;i.Data.Mouse.Flags=0x0800;i.Data.Mouse.Data=unchecked((uint)delta);
      if(SendInput(1,new Input[]{i},Marshal.SizeOf(typeof(Input)))!=1)throw new InvalidOperationException("Wheel input refused");
    }finally{SetThreadDpiAwarenessContext(old);}
  }
  // Order the owned receiver over (cover) or away from (uncover) an App client point, without
  // changing activation.
  public static void ReceiverCover(IntPtr app,int process,double x,double y,bool cover){
    HoverGuard(app,process);IntPtr old=SetThreadDpiAwarenessContext(new IntPtr(-4));
    try{lock(receiverGate){
      if(!receiverReady||receiverOwner!=process||receiverWindow==IntPtr.Zero)throw new InvalidOperationException("Receiver unavailable");
      Point p=HoverClientPoint(app,x,y);Rect b;GetWindowRect(app,out b);
      int w=300,h=160,left=cover?p.X-w/2:b.Left+20,top=cover?p.Y-h/2:b.Bottom-h-20;
      if(!cover&&left<=p.X&&p.X<left+w&&top<=p.Y&&p.Y<top+h)top=b.Top+20;
      if(!SetWindowPos(receiverWindow,new IntPtr(-1),left,top,w,h,0x50))throw new InvalidOperationException("Receiver placement failed");
      Point probe=p;bool over=GetAncestor(WindowFromPoint(probe),2)==receiverWindow;
      if(over!=cover)throw new InvalidOperationException(cover?"Receiver does not cover the point":"Receiver still covers the point");
    }}finally{SetThreadDpiAwarenessContext(old);}
  }
  public static System.Collections.Hashtable ReceiverStatus(){lock(receiverGate){return new System.Collections.Hashtable{{"ok",true},{"ready",receiverReady},{"thread_alive",receiverThread!=null&&receiverThread.IsAlive},{"foreground",receiverWindow!=IntPtr.Zero&&GetForegroundWindow()==receiverWindow},{"left_button_down",GetAsyncKeyState(1)<0},{"pid",System.Diagnostics.Process.GetCurrentProcess().Id},{"hwnd",receiverWindow.ToInt64()},{"drops",receiverDrops},{"enters",receiverEnters},{"leaves",receiverLeaves},{"kind",receiverKind},{"effect",receiverEffect},{"keys",receiverKeys},{"length",receiverLength},{"hash",receiverHash},{"files_exist",receiverFilesExist},{"error",receiverError}};}}
  public static bool Text(string text,int process) {
    foreach(char c in text) {
      if(!Owned(GetForegroundWindow(),process))return false;
      Input down=new Input();down.Type=1;down.Data.Key.Scan=c;down.Data.Key.Flags=4;
      Input up=down;up.Data.Key.Flags=6;
      uint accepted=SendInput(2,new Input[]{down,up},Marshal.SizeOf(typeof(Input)));
      if(accepted!=2){if(accepted==1)SendInput(1,new Input[]{up},Marshal.SizeOf(typeof(Input)));return false;}
    }
    return true;
  }
}
'@
}
function Get-WindowsNativeStatus($proc, [bool]$InspectionOnly = $false) {
  Initialize-WindowsNativeInput
  $proc.Refresh()
  $hwnd=if($InspectionOnly){[ZenitNativeInput]::StatusWindow($proc.Id)}else{[ZenitNativeInput]::AppWindow($proc.Id)}
  if ($proc.HasExited -or $hwnd -eq [IntPtr]::Zero) { throw 'Owned native window unavailable' }
  $open=[ZenitNativeInput]::Open($hwnd)
  $conversion=[ZenitNativeInput]::Conversion($hwnd)
  $foreground=[ZenitNativeInput]::GetForegroundWindow()
  $owned=[ZenitNativeInput]::Owned($foreground,$proc.Id)
  return @{ok=$true; visible=[ZenitNativeInput]::IsWindowVisible($hwnd); minimized=[ZenitNativeInput]::IsIconic($hwnd); windows=@([ZenitNativeInput]::WindowInventory($proc.Id)); foreground_hwnd=$foreground.ToInt64(); foreground_owned=$owned; foreground_title=$(if($owned){[ZenitNativeInput]::Title($foreground)}else{''}); foreground_class=$(if($owned){[ZenitNativeInput]::Class($foreground)}else{''}); foreground_owner=$(if($owned){([ZenitNativeInput]::GetWindow($foreground,4)).ToInt64()}else{0}); pid=$proc.Id; hwnd=$hwnd.ToInt64(); foreground=($foreground -eq $hwnd); layout=[ZenitNativeInput]::Layout($hwnd); ime_open=$(if($open -ge 0){$open -eq 1}else{$null}); conversion=$(if($conversion -ge 0){$conversion}else{$null}); session=$proc.SessionId}
}
function Invoke-WindowsNativeInput($proc, $body, $held) {
  Initialize-WindowsNativeInput
  if ($body.action -eq 'receiver-status') { return [ZenitNativeInput]::ReceiverStatus() }
  if ($body.action -eq 'receiver-stop') { [ZenitNativeInput]::ReceiverStop();return @{ok=$true} }
  if ($body.action -eq 'drag-cancel') { [ZenitNativeInput]::DragCancel();return @{ok=$true} }
  # Inventory/foreground observation has no target window. In a background
  # multi-window suite the foreground may belong to another app, so do not
  # fall back to AppWindow's deliberately strict single-input-target guard.
  if ($body.action -eq 'status' -and $body.inventory_only -eq $true) {
    $proc.Refresh()
    if ($proc.HasExited) { throw 'Owned native process unavailable' }
    $windows=@([ZenitNativeInput]::WindowInventory($proc.Id))
    if ($windows.Count -eq 0) { throw 'Owned native window unavailable' }
    $foreground=[ZenitNativeInput]::GetForegroundWindow()
    return @{ok=$true; pid=$proc.Id; windows=$windows; foreground_hwnd=$foreground.ToInt64(); foreground_owned=[ZenitNativeInput]::Owned($foreground,$proc.Id); session=$proc.SessionId}
  }
  $status=Get-WindowsNativeStatus $proc ($body.action -eq 'status')
  $hwnd=[IntPtr]::new([long]$status.hwnd)
  if ($body.action -eq 'uia-tree') { return Get-WindowsUiaTree $proc }
  if ($body.action -in @('uia-invoke','uia-toggle','uia-set-value','uia-set-range','uia-select','uia-expand','uia-text-action')) { return Invoke-WindowsUiaControl $proc $body }
  if ($body.action -eq 'status') { return $status }
  if ($body.action -eq 'activate') {
    [ZenitNativeInput]::ActivateOwned($hwnd,$proc.Id)
    Start-Sleep -Milliseconds 100
    $status=Get-WindowsNativeStatus $proc
    if (-not $status.foreground) { throw 'Owned native window could not acquire foreground' }
    return $status
  }
  if ($body.action -eq 'hover-pointer-at') { [ZenitNativeInput]::HoverPointerAt($hwnd,$proc.Id,[double]$body.x,[double]$body.y);return @{ok=$true;foreground=$status.foreground} }
  if ($body.action -eq 'hover-wheel') { [ZenitNativeInput]::HoverWheel($hwnd,$proc.Id,[int]$body.delta);return @{ok=$true;foreground=$status.foreground} }
  if ($body.action -in @('receiver-cover','receiver-uncover')) { [ZenitNativeInput]::ReceiverCover($hwnd,$proc.Id,[double]$body.x,[double]$body.y,$body.action -eq 'receiver-cover');return @{ok=$true;foreground=$status.foreground} }
  if ($body.action -eq 'drag-status') { return @{ok=$true;active=[ZenitNativeInput]::DragActive();done=[ZenitNativeInput]::DragDone();effect=[ZenitNativeInput]::DragEffect();error=[ZenitNativeInput]::DragError();diagnostic=[ZenitNativeInput]::DragDiagnostic();foreground=$status.foreground_hwnd;source_foreground=[ZenitNativeInput]::SourceForeground($proc.Id)} }
  if (-not $status.foreground_owned -and -not [ZenitNativeInput]::SourceForeground($proc.Id)) { throw 'Native input refused: foreground is not owned by the test process' }
  if ($body.action -eq 'close') {
    [ZenitNativeInput]::CloseOwned($hwnd,$proc.Id)
    $exited=$proc.WaitForExit(5000)
    return @{ok=$exited; error=$(if(-not $exited){'Owned close timed out'}else{''}); exited=$exited; exit_code=$(if($exited){$proc.ExitCode}else{$null}); hwnd_alive=[ZenitNativeInput]::IsWindow($hwnd)}
  }
  if ($body.action -eq 'caption-toggle') { [ZenitNativeInput]::CaptionToggle($hwnd,$proc.Id);return @{ok=$true} }
  if ($body.action -eq 'drag-start') {
    [ZenitNativeInput]::DragStart($hwnd,$proc.Id,[double]$body.x,[double]$body.y,[string]$body.kind,[string]$body.text,[string[]]@($body.files),[int]$body.operations)
    return @{ok=$true}
  }
  if ($body.action -eq 'receiver-start') { [ZenitNativeInput]::ReceiverStart($hwnd,$proc.Id,[int]$body.operations,[bool]$body.logical);return @{ok=$true} }
  if ($body.action -eq 'receiver-move') { [ZenitNativeInput]::ReceiverMove($hwnd,$proc.Id);return @{ok=$true} }
  if ($body.action -eq 'receiver-activate') { [ZenitNativeInput]::ReceiverActivate($hwnd,$proc.Id);return @{ok=$true} }
  if ($body.action -eq 'pointer-down') { [ZenitNativeInput]::PointerDown($hwnd,$proc.Id,[double]$body.x,[double]$body.y);return @{ok=$true} }
  if ($body.action -eq 'drag-move') { [ZenitNativeInput]::DragMove($hwnd,$proc.Id,[double]$body.x,[double]$body.y);return @{ok=$true} }
  if ($body.action -eq 'drag-release') { [ZenitNativeInput]::DragRelease();return @{ok=$true} }
  if ($body.action -eq 'text') {
    $text=[string]$body.text
    if ($text.Length -gt 4096 -or $text.IndexOf([char]0) -ge 0) { throw 'Invalid native text length/content' }
    if (-not [ZenitNativeInput]::Text($text,$proc.Id)) { throw 'Native Unicode input rejected' }
    return @{ok=$true}
  }
  if ($body.action -eq 'chord') {
    $keys=@($body.keys)
    if ($keys.Count -lt 1 -or $keys.Count -gt 4) { throw 'Invalid native chord length' }
    foreach ($vk in $keys) { if ([int]$vk -lt 1 -or [int]$vk -gt 254) { throw 'Invalid native chord key' } }
    try {
      foreach ($vk in $keys) {
        if (-not [ZenitNativeInput]::Key([int]$vk,$false)) { throw 'Native chord key down rejected' }
        $held.Add([int]$vk) | Out-Null
      }
    } finally {
      for ($i=$keys.Count-1;$i -ge 0;$i--) {
        [ZenitNativeInput]::Key([int]$keys[$i],$true) | Out-Null
        $held.Remove([int]$keys[$i]) | Out-Null
      }
    }
    return @{ok=$true}
  }
  if ($body.action -eq 'key') {
    $vk=[int]$body.vk
    if ($body.edge -notin @('down','up','press') -or $vk -lt 1 -or $vk -gt 254) { throw 'Invalid native key' }
    if ($body.edge -ne 'up') {
      if (-not [ZenitNativeInput]::Key($vk,$false)) { throw 'Native key down was not accepted' }
      $held.Add($vk) | Out-Null
    }
    if ($body.edge -ne 'down') {
      if (-not [ZenitNativeInput]::Key($vk,$true)) { throw 'Native key up was not accepted' }
      $held.Remove($vk) | Out-Null
    }
    return @{ok=$true; vk=$vk; edge=$body.edge}
  }
  throw 'Unknown native input action'
}
