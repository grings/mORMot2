/// TFTP Server-Side Process 
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit mormot.net.tftp.server;

{
  *****************************************************************************

    TFTP Server Processing with RFC 1350/2347/2348/2349/7440 Support
    - Abstract UDP Server
    - TFTP Connection Thread and State Machine
    - TServerTftp Server Class

    Current limitation: only RRQ requests are supported yet.

  *****************************************************************************

}

interface

{$I ..\mormot.defines.inc}

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.data,
  mormot.core.threads,
  mormot.core.rtti,
  mormot.core.buffers,
  mormot.net.sock,
  mormot.net.tftp.client;



{ ******************** Abstract UDP Server }

type
  /// work memory buffer of the maximum size of UDP frame (64KB)
  TUdpFrame = array[word] of byte;

  /// pointer to a memory buffer of the maximum size of UDP frame
  PUdpFrame = ^TUdpFrame;

  /// abstract UDP server thread
  TUdpThread = class(TNotifiedThread)
  protected
    fSock: TNetSocket;
    fSockAddr: TNetAddr;
    fExecuteMessage: RawUtf8;
    fProcessing: boolean;
    fFrame: PUdpFrame;
    // this is the main processing method for all incoming frames
    procedure OnFrameReceived(len: integer; var remote: TNetAddr); virtual; abstract;
    procedure OnShutdown; virtual; abstract;
    procedure OnIdle; virtual;
  public
    /// initialize and bind the server instance, in non-suspended state
    constructor Create(const OnStart, OnStop: TOnNotifyThread;
      const BindAddress, BindPort, ProcessName: RawUtf8); reintroduce;
    /// finalize the processing thread
    destructor Destroy; override;
    /// will loop for any pending UDP frame, and execute FrameReceived method
    procedure Execute; override;
    /// notify the thread to be terminated, and wait for all connections to be
    // closed
    procedure ShutdownAndWait;
  end;


{ ******************** TFTP Connection Thread and State Machine }

type
  /// tune what is TTftpThread accepting
  TTftpThreadOption = (
    ttoRrq,
    ttoWrq);

  TTftpThreadOptions = set of TTftpThreadOption;

  /// server thread handling several TFTP connections
  // - a single thread will bind to the supplied UDP address:port, then will
  // process any incoming requests from UDP packets
  // - each connection will maintain its own state machine, and the main thred
  // will process all connection clients one after the other
  TTftpThread = class(TUdpThread)
  protected
    fConnection: TTftpContextDynArray;
    fConnectionCount: integer;
    fConnections: TDynArray;
    fFileFolder: TFileName;
    fOptions: TTftpThreadOptions;
    fMaxConnections: integer;
    fMaxRetry: integer;
    fOnFileDataStream: TStream;
    procedure SetFileFolder(const Value: TFileName); virtual;
    function SendFrame(var ctxt: TTftpContext): boolean;
    procedure RemoveConnection(conn: PTftpContext); virtual;
    // default implementation will read/write from FileFolder
    function GetFileName(const FileName: RawUtf8): TFileName; virtual;
    function GetRrqStream(var Context: TTftpContext): TTftpError; virtual;
    function GetWrqStream(var Context: TTftpContext): TTftpError; virtual;
    // main processing methods for all incoming frames
    procedure OnFrameReceived(len: integer; var remote: TNetAddr); override;
    procedure OnIdle; override;
    procedure OnShutdown; override;
  public
    /// initialize and bind the server instance, in non-suspended state
    constructor Create(const SourceFolder: TFileName; Options: TTftpThreadOptions;
      const OnStart, OnStop: TOnNotifyThread;
      const BindAddress, BindPort, ProcessName: RawUtf8); reintroduce;
  published
    /// how many requests are currently used
    property ConnectionCount: integer
      read fConnectionCount;
    /// how many concurrent requests are allowed at most - default is 100
    property MaxConnections: integer
      read fMaxConnections write fMaxConnections;
    /// how many retries should be done after timeout - default is 5
    property MaxRetry: integer
      read fMaxRetry write fMaxRetry;
    /// the local folder where the files are read or written
    property FileFolder: TFileName
      read fFileFolder write SetFileFolder;
  end;



{ ******************** TServerTftp Asynchronous Server Class }




implementation


{ ******************** Abstract UDP Server }

{ TUdpThread }

procedure TUdpThread.OnIdle;
begin
end;

constructor TUdpThread.Create(const OnStart, OnStop: TOnNotifyThread;
  const BindAddress, BindPort, ProcessName: RawUtf8);
var
  ident: RawUtf8;
  res: TNetResult;
begin
  GetMem(fFrame, SizeOf(fFrame^));
  ident := ProcessName;
  if ident <> '' then
    FormatUtf8('udp%srv', [BindPort], ident);
  res := NewSocket(BindAddress, BindPort, nlUdp, {bind=}true,
    5000, 5000, 5000, 10, fSock, @fSockAddr);
  if res <> nrOk then
    // on binding error, raise exception before the thread is actually created
    raise ENetSock.Create('%s.Create binding error on %s:%s',
      [ClassNameShort(self)^, BindAddress, BindPort], res);
  inherited Create({suspended=}false, OnStart, OnStop, ident);
end;

destructor TUdpThread.Destroy;
begin
  ShutdownAndWait;
  inherited Destroy;
  if fSock <> nil then
    fSock.ShutdownAndClose({rdwr=}true);
  FreeMem(fFrame);
end;

procedure TUdpThread.Execute;
var
  len: integer;
  tix, lasttix: cardinal;
  remote: TNetAddr;
  res: TNetResult;
begin
  fProcessing := true;
  NotifyThreadStart(self);
  lasttix := 0;
  // main server process loop
  try
    if fSock = nil then // paranoid check
      raise ENetSock.CreateFmt('%.Execute: Bind failed', [ClassNameShort(self)^]);
    while not Terminated do
    begin
      if fSock.WaitFor(1000, [neRead]) <> [] then
      begin
        if Terminated then
          break;
        res := fSock.RecvPending(len);
        if (res = nrOk) and
           (len >= 4) then
        begin
          PInteger(fFrame)^ := 0;
          len := fSock.RecvFrom(fFrame, SizeOf(fFrame^), remote);
          if len >= 0 then // -1=error, 0=shutdown
            OnFrameReceived(len, remote);
        end;
      end;
      tix := mormot.core.os.GetTickCount64 shr 9;
      if tix <> lasttix then
      begin
        lasttix := tix;
        OnIdle; // called every 512 ms at most
      end;
    end;
    OnShutdown; // should close all connections
  except
    on E: Exception do
      // any exception would break and release the thread
      FormatUtf8('% [%]', [E, E.Message], fExecuteMessage);
  end;
  fProcessing := false;
end;

procedure TUdpThread.ShutdownAndWait;
begin
  if not fProcessing then
    exit;
  Terminate;
  SleepHiRes(5000, fProcessing, {terminated=}false);
end;


{ ******************** TFTP Connection Thread and State Machine }

{ TTftpThread }

constructor TTftpThread.Create(const SourceFolder: TFileName;
  Options: TTftpThreadOptions; const OnStart, OnStop: TOnNotifyThread;
  const BindAddress, BindPort, ProcessName: RawUtf8);
begin
  SetFileFolder(SourceFolder);
  fMaxConnections := 100; // good enough for a TFTP instance
  fMaxRetry := 5;
  fOptions := Options;
  inherited Create(OnStart, OnStop, BindAddress, BindPort, ProcessName);
end;

procedure TTftpThread.SetFileFolder(const Value: TFileName);
begin
  if fFileFolder <> Value then
    fFileFolder := IncludeTrailingPathDelimiter(Value);
end;

function TTftpThread.GetFileName(const FileName: RawUtf8): TFileName;
begin
  result := NormalizeFileName(Utf8ToString(FileName));
  if SafeFileName(result) then
    result := fFileFolder + result
  else
    result := '';
end;

const
  RRQ_MEM_CHUNK = 128 shl 10; // buffered read in 128KB chunks

function TTftpThread.GetRrqStream(var Context: TTftpContext): TTftpError;
var
  fn: TFileName;
begin
  if ttoRrq in fOptions then
  begin
    result := teFileNotFound;
    fn := GetFileName(Context.FileName);
    if (fn = '') or
       not FileExists(Context.FileName) then
      exit;
    Context.FileStream := TBufferedStreamReader.Create(fn, RRQ_MEM_CHUNK);
    if Context.FileStream.Size < maxInt then
      result := teNoError
    else
      FreeAndNil(Context.FileStream);
  end
  else
    result := teIllegalOperation;
end;

function TTftpThread.GetWrqStream(var Context: TTftpContext): TTftpError;
var
  fn: TFileName;
begin
  if ttoWrq in fOptions then
  begin
    result := teFileAlreadyExists;
    fn := GetFileName(Context.FileName);
    if (fn = '') or
       FileExists(Context.FileName) then
      exit;
    Context.FileStream := TFileStream.Create(fn, fmCreate);
    result := teNoError;
  end
  else
    result := teIllegalOperation;
end;

function TTftpThread.SendFrame(var ctxt: TTftpContext): boolean;
begin
  result := (ctxt.FrameLen = 0) or
            (fSock.SendTo(ctxt.Frame, ctxt.FrameLen, ctxt.Remote) = nrOK);
  if result then
    ctxt.SetTimeoutTix;
end;

procedure TTftpThread.RemoveConnection(conn: PTftpContext);
begin
  if conn = nil then
    exit;
  conn^.FileStream.Free;
  fConnections.Delete((PtrUInt(conn) - PtrUInt(fConnection)) div SizeOf(conn^));
end;

function GetConnection(conn: PTftpContext; var addr: TNetAddr; n: integer): PTftpContext;
{$ifdef CPU64}
var
  i64: Int64;
{$endif CPU64}
begin
  if n > 0 then
  begin
    result := conn;
    {$ifdef CPU64}
    i64 := PInt64(@addr)^;
    {$endif CPU64}
    repeat
      // TTftpContext.Remote is the first field
      {$ifdef CPU64}
      if PInt64(result)^ <> i64 then // very fast brute force O(n) search
      {$else}
      if PInt64(result)^ <> PInt64(@addr)^ then
      {$endif CPU64}
      begin
        inc(result); // most common case within the loop is to continue
        dec(n);
        if n = 0 then
          break
        else
          continue;
      end
      else if result^.Remote.IsEqualAfter64(addr) then
        exit;
      inc(result);
      dec(n);
      if n = 0 then
        break;
    until false;
  end;
  result := nil;
end;

procedure TTftpThread.OnFrameReceived(len: integer; var remote: TNetAddr);

  procedure SendError(err: TTftpError; c: PTftpContext = nil;
    const msg: RawUtf8 = '');
  var
    ctxt: TTftpContext;
  begin
    ctxt.Remote := remote;
    ctxt.Frame := pointer(fFrame);
    ctxt.GenerateErrorFrame(err, msg);
    SendFrame(ctxt);
    if c <> nil then
      RemoveConnection(c);
  end;

var
  op: TTftpOpcode;
  res: TTftpError;
  c: PTftpContext;
  new: TTftpContext;
begin
  // frame is in fFrame/len
  c := GetConnection(pointer(fConnection), remote, fConnectionCount);
  if len = 0 then // fSock.RecvFrom=0 on shutdown
  begin
    RemoveConnection(c);
    exit;
  end;
  op := ToOpCode(PTftpFrame(fFrame)^);
  if (op = toUndefined) or
     (len < 4) then
    // invalid frame
    exit;
  case op of
    toRrq,
    toWrq:
      // new request
      if c <> nil then
        SendError(teIllegalOperation, c, 'Already Active Connection')
      else if fConnectionCount > fMaxConnections then
        SendError(teIllegalOperation, c, 'Too Many Connections')
      else
      begin
        FillCharFast(new, SizeOf(new), 0);
        new.Remote := remote;
        new.Socket := remote.NewSocket(nlUdp); // create new ephemeral port
        if new.Socket = nil then
          exit;
        new.Socket.SetReceiveTimeout(1000);
        case op of
          toRrq:
            res := GetRrqStream(new);
          toWrq:
            res := GetWrqStream(new);
        else
          res := teIllegalOperation;
        end;
        if res = teNoError then
          res := new.ParseRequest(fFrame, len);
        if res <> teNoError then
        begin
          SendError(res);
          new.FileStream.Free;
        end
        else if SendFrame(new) then // send ACK/OACK
          fConnections.Add(new)
        else
          new.FileStream.Free;
      end;
    toDat, // during WRQ
    toAck: // during RRQ
      begin
        if c = nil then
          res := teIllegalOperation
        else
          res := c^.ParseData(op, len);
        case res of
          teNoError:
            case op of
              toAck:
                // send next RRQ block(s)
                repeat
                  if not SendFrame(c^) then
                  begin
                    RemoveConnection(c);
                    exit;
                  end;
                  dec(c^.LastReceivedSequenceWindowCounter);
                  if c^.LastReceivedSequenceWindowCounter = 0 then
                    break;
                  c^.GenerateNextDataFrame;
                until c^.FrameLen < 0;
                // note: this pattern expect the OS buffer to be big enough
                // for sending all frames: WindowSize should remain small
              toDat:
                // send ACK after received next WRQ block
                if not SendFrame(c^) then
                begin
                  RemoveConnection(c);
                  exit;
                end;
            end;
          teFinished:
            begin
              if op = toDat then
                SendFrame(c^); // final WRQ acknowledge
              RemoveConnection(c);
            end
        else
          SendError(res);
        end;
      end;
    toErr:
      RemoveConnection(c);
  end;
end;

procedure TTftpThread.OnIdle;
var
  i: PtrInt;
  tix: Int64;
begin
  if fConnectionCount = 0 then
    exit;
  tix := mormot.core.os.GetTickCount64;
  for i := fConnectionCount - 1 downto 0 do
    with fConnection[i] do
      if TimeoutTix >= tix then
        // we didn't receive the ACK in the expected time frame
        if RetryCount = fMaxRetry then
          RemoveConnection(@fConnection[i])
        else
        begin

          inc(RetryCount);
        end;
end;

procedure TTftpThread.OnShutdown;
var
  i: PtrInt;
begin
  // called by Executed on Terminated
  for i := 0 to fConnectionCount - 1 do
    fConnection[i].Close;
end;



{ ******************** TServerTftp Asynchronous Server Class }

end.

