#!/usr/bin/env python3
# =============================================================================
# api-server.py -- Droplet Status API (HTTP server on port 8080)
# =============================================================================
# Purpose:  Lightweight HTTP API exposing droplet provisioning status.
#           Provides status, health, config endpoints for droplet management.
#
# Endpoints:
#   GET  /status  -- Full status JSON (phase, stage, services, safe_mode)
#   GET  /health  -- Health check (200 if bot online, 503 if not)
#   GET  /stages  -- Raw init-stages.log text
#   GET  /log     -- Last 8KB of bootstrap/phase logs
#   GET  /config  -- Config file status (no sensitive data)
#   GET  /config/status -- API upload status only (no auth required)
#   POST /sync    -- Trigger openclaw state sync to Dropbox
#   POST /prepare-shutdown -- Sync state and stop openclaw for shutdown
#   POST /keepalive -- Reset self-destruct timer (HMAC auth required)
#   POST /config/upload -- Upload habitat and/or agents JSON (base64 supported)
#   POST /config/apply  -- Apply uploaded config and restart
#
# Dependencies: systemctl, /usr/local/bin/sync-openclaw-state.sh,
#               /usr/local/bin/apply-config.sh
#
# Original: /usr/local/bin/api-server.py (in hatch.yaml write_files)
# =============================================================================
import http.server,socketserver,subprocess,json,os,base64,hmac,hashlib,time
PORT=8080
API_SECRET=os.getenv('API_SECRET','')
API_BIND_ADDRESS=os.getenv('API_BIND_ADDRESS','127.0.0.1')
HABITAT_PATH='/etc/habitat.json'
AGENTS_PATH='/etc/agents.json'
MARKER_PATH='/etc/config-api-uploaded'
APPLY_SCRIPT='/usr/local/bin/apply-config.sh'
P1_STAGES={0:"init",1:"preparing",2:"installing-bot",3:"bot-online"}
P2_STAGES={4:"desktop-environment",5:"developer-tools",6:"browser-tools",7:"desktop-services",8:"skills-apps",9:"remote-access",10:"finalizing",11:"ready"}

def check_service(name):
  try:r=subprocess.run(["systemctl","is-active",name],capture_output=True,timeout=5);return r.stdout.decode().strip()=="active"
  except:return False

def get_status():
  # Check completion markers first to determine smart defaults
  p1_done=os.path.exists('/var/lib/init-status/phase1-complete')
  p2_done=os.path.exists('/var/lib/init-status/phase2-complete')
  setup_done=os.path.exists('/var/lib/init-status/setup-complete')
  needs_check=os.path.exists('/var/lib/init-status/needs-post-boot-check')
  
  # Smart defaults based on completion state (handles transient read failures during reboot)
  # needs-post-boot-check exists during reboot until post-boot-check.sh completes
  if setup_done and not needs_check:
    s,p=11,2  # Ready state (fully booted)
  elif setup_done and needs_check:
    s,p=10,2  # Rebooting (setup done but post-boot-check pending)
  elif p2_done:
    s,p=10,2  # Phase 2 done, finalizing
  elif p1_done:
    s,p=4,2   # Phase 1 done, starting phase 2
  else:
    s,p=0,1   # Initial state
  
  # Try to read actual values (overrides defaults if successful)
  try:
    with open('/var/lib/init-status/stage','r') as f:
      val=f.read().strip()
      if val:s=int(val)
    with open('/var/lib/init-status/phase','r') as f:
      val=f.read().strip()
      if val:p=int(val)
  except:pass
  
  # Check bot status based on isolation mode
  # Read isolation config from habitat-parsed.env
  isolation_mode="none"
  isolation_groups=[]
  try:
    with open('/etc/habitat-parsed.env','r') as f:
      for line in f:
        if line.startswith('ISOLATION_DEFAULT='):
          isolation_mode=line.split('=',1)[1].strip().strip('"')
        elif line.startswith('ISOLATION_GROUPS='):
          groups_str=line.split('=',1)[1].strip().strip('"')
          if groups_str:
            isolation_groups=groups_str.split(',')
  except:pass
  
  # Determine bot_online based on isolation mode
  if isolation_mode=="session" and isolation_groups:
    # Session isolation: check if ANY session service is running
    bot_online=any(check_service(f'openclaw-{g}') for g in isolation_groups)
  elif isolation_mode=="container":
    # Container isolation: check containers service
    bot_online=check_service('openclaw-containers')
  else:
    # No isolation: check main clawdbot
    bot_online=check_service('clawdbot')
  
  svc={}
  if p2_done or setup_done:
    # Include isolation services in status
    base_services=['xrdp','desktop','x11vnc']
    if isolation_mode=="session" and isolation_groups:
      for g in isolation_groups:
        svc[f'openclaw-{g}']=check_service(f'openclaw-{g}')
    elif isolation_mode=="container":
      svc['openclaw-containers']=check_service('openclaw-containers')
    else:
      svc['clawdbot']=check_service('clawdbot')
    for sv in base_services:
      svc[sv]=check_service(sv)
  desc=P1_STAGES.get(s) if p==1 else P2_STAGES.get(s,f"stage-{s}")
  safe_mode=os.path.exists('/var/lib/init-status/safe-mode')
  rebooting=setup_done and needs_check  # System rebooted, waiting for post-boot-check
  return {"phase":p,"stage":s,"desc":desc,"bot_online":bot_online,"phase1_complete":p1_done,"phase2_complete":p2_done,"ready":setup_done and bot_online and not needs_check,"rebooting":rebooting,"safe_mode":safe_mode,"services":svc if svc else None}

def validate_config_upload(data):
  """Validate config upload request data."""
  errors=[]
  if "habitat" in data and not isinstance(data["habitat"],dict):errors.append("habitat must be an object")
  if "globals" in data and not isinstance(data["globals"],dict):errors.append("globals must be an object")
  if "agents" in data and not isinstance(data["agents"],dict):errors.append("agents must be an object")
  if "globals" in data and not isinstance(data["globals"],dict):errors.append("globals must be an object")
  if "apply" in data and not isinstance(data["apply"],bool):errors.append("apply must be a boolean")
  return errors

# Valid global fields that can be merged into habitat
GLOBAL_FIELDS = [
  "globalIdentity", "globalSoul", "globalAgents", "globalBoot",
  "globalBootstrap", "globalTools", "globalUser"
]

def merge_globals_into_habitat(globals_data):
  """Merge globals into existing habitat.json.
  
  Reads /etc/habitat.json, merges the global fields, writes back.
  Only merges known global fields to prevent injection of other config.
  """
  if not os.path.exists(HABITAT_PATH):
    return {"ok":False,"error":"No habitat.json exists to merge into"}
  
  try:
    with open(HABITAT_PATH,'r') as f:
      habitat=json.load(f)
  except Exception as e:
    return {"ok":False,"error":f"Failed to read habitat.json: {e}"}
  
  # Only merge known global fields
  merged_fields=[]
  for field in GLOBAL_FIELDS:
    if field in globals_data:
      habitat[field]=globals_data[field]
      merged_fields.append(field)
  
  # Write merged habitat back
  try:
    with open(HABITAT_PATH,'w') as f:
      json.dump(habitat,f,indent=2)
    os.chmod(HABITAT_PATH,0o600)
    return {"ok":True,"merged_fields":merged_fields}
  except Exception as e:
    return {"ok":False,"error":f"Failed to write merged habitat: {e}"}

def write_config_file(path,data):
  """Write config data to file with secure permissions."""
  try:
    with open(path,'w') as f:json.dump(data,f,indent=2)
    os.chmod(path,0o600)
    return {"ok":True,"path":path}
  except Exception as e:return {"ok":False,"error":str(e)}

def write_upload_marker():
  """Write API upload marker with timestamp.
  
  Creates /etc/config-api-uploaded file with timestamp to indicate successful
  config upload via POST /config/upload endpoint. Used by /config/status to
  report upload state.
  
  API Upload Marker Semantics (Issue #115, #119):
  -----------------------------------------------
  The marker file distinguishes between two config provisioning modes:
  
  1. API-UPLOADED MODE (api_uploaded=True):
     - Config was uploaded via POST /config/upload endpoint
     - Marker file exists with upload timestamp
     - Typical flow: iOS Shortcut → API → config files → apply
  
  2. APPLY-ONLY MODE (api_uploaded=False):
     - Config was placed manually or via cloud-init (never API-uploaded)
     - Marker file does NOT exist
     - Config may still be valid and functional
     - Typical flow: cloud-init → config files → apply
  
  Why This Matters:
  - Polling clients can distinguish "never configured" from "configured locally"
  - Enables workflows where some droplets use API, others use cloud-init
  - api_uploaded=False + habitat_exists=True = apply-only mode
  - api_uploaded=False + habitat_exists=False = unconfigured
  
  Logs success/failure in structured format to stderr. Failures are non-fatal
  since upload status can still be determined via API (file existence check).
  
  Returns:
    dict: {"ok": bool, "path": str, "error": str (if failed)}
  """
  import sys
  timestamp = time.time()
  
  try:
    with open(MARKER_PATH, 'w') as f:
      f.write(str(timestamp))
    os.chmod(MARKER_PATH, 0o600)
    
    # Log success (structured format for parsing/monitoring)
    log_entry = json.dumps({
      "event": "upload_marker_written",
      "path": MARKER_PATH,
      "timestamp": timestamp,
      "success": True
    })
    print(log_entry, file=sys.stderr)
    
    return {"ok": True, "path": MARKER_PATH}
    
  except PermissionError as e:
    error_msg = f"Permission denied writing marker: {e}"
    log_entry = json.dumps({
      "event": "upload_marker_write_failed",
      "path": MARKER_PATH,
      "timestamp": timestamp,
      "success": False,
      "error": "PermissionError",
      "details": str(e)
    })
    print(log_entry, file=sys.stderr)
    return {"ok": False, "error": error_msg}
    
  except OSError as e:
    # Covers: disk full, directory doesn't exist, filesystem errors
    error_msg = f"OS error writing marker: {e}"
    log_entry = json.dumps({
      "event": "upload_marker_write_failed",
      "path": MARKER_PATH,
      "timestamp": timestamp,
      "success": False,
      "error": "OSError",
      "details": str(e)
    })
    print(log_entry, file=sys.stderr)
    return {"ok": False, "error": error_msg}
    
  except Exception as e:
    # Catch-all for unexpected errors
    error_msg = f"Unexpected error writing marker: {e}"
    log_entry = json.dumps({
      "event": "upload_marker_write_failed",
      "path": MARKER_PATH,
      "timestamp": timestamp,
      "success": False,
      "error": type(e).__name__,
      "details": str(e)
    })
    print(log_entry, file=sys.stderr)
    return {"ok": False, "error": error_msg}

def get_config_status():
  """Get current config file status (authenticated endpoint).
  
  Returns detailed config status including file existence, modification times,
  and API upload status. Does not expose sensitive data (no tokens, secrets).
  
  Config State Matrix (Issue #119):
  ---------------------------------
  | api_uploaded | habitat_exists | State                              |
  |--------------|----------------|-------------------------------------|
  | False        | False          | Unconfigured (fresh droplet)        |
  | False        | True           | Apply-only (manual/cloud-init)      |
  | True         | False          | Error (marker without config)       |
  | True         | True           | API-provisioned (normal flow)       |
  
  Apply-Only Mode:
  - habitat_exists=True but api_uploaded=False
  - Config was placed via cloud-init or manual copy, then applied
  - This is valid and functional; API upload is optional
  - Polling clients should check habitat_exists, not just api_uploaded
  
  Returns:
    dict: {
      "habitat_exists": bool,
      "agents_exists": bool,
      "habitat_modified": float (mtime, if exists),
      "agents_modified": float (mtime, if exists),
      "habitat_name": str (if exists),
      "habitat_agent_count": int (if exists),
      "agents_names": list[str] (if exists),
      "api_uploaded": bool,
      "api_uploaded_at": float (timestamp, if api_uploaded)
    }
  """
  result={"habitat_exists":os.path.exists(HABITAT_PATH),"agents_exists":os.path.exists(AGENTS_PATH)}
  if result["habitat_exists"]:
    stat=os.stat(HABITAT_PATH);result["habitat_modified"]=stat.st_mtime
    try:
      with open(HABITAT_PATH,'r') as f:h=json.load(f)
      result["habitat_name"]=h.get("name","")
      result["habitat_agent_count"]=len(h.get("agents",[]))
    except:pass
  if result["agents_exists"]:
    stat=os.stat(AGENTS_PATH);result["agents_modified"]=stat.st_mtime
    try:
      with open(AGENTS_PATH,'r') as f:a=json.load(f)
      result["agents_names"]=list(a.keys())
    except:pass
  # Check API upload marker (issue #115)
  if os.path.exists(MARKER_PATH):
    result["api_uploaded"]=True
    try:
      with open(MARKER_PATH,'r') as f:result["api_uploaded_at"]=float(f.read().strip())
    except:pass
  else:
    result["api_uploaded"]=False
  return result

def get_config_upload_status():
  """Get simple config upload status for unauthenticated endpoint.
  
  Lightweight endpoint for polling (Issue #130). Returns ONLY the api_uploaded
  status, not full config details (which require authentication).
  
  IMPORTANT (Issue #119): api_uploaded=False does NOT mean "unconfigured".
  It means config was never uploaded via the API. The config may still exist
  and be functional (apply-only mode via cloud-init or manual placement).
  
  For full config state, use GET /config (authenticated) which includes
  habitat_exists and agents_exists flags.
  
  Returns:
    dict: {
      "api_uploaded": bool,        # True if config was uploaded via API
      "api_uploaded_at": float     # Unix timestamp of upload (if api_uploaded)
    }
  """
  result={"api_uploaded":False,"api_uploaded_at":None}
  if os.path.exists(MARKER_PATH):
    result["api_uploaded"]=True
    try:
      with open(MARKER_PATH,'r') as f:result["api_uploaded_at"]=float(f.read().strip())
    except:pass
  return result

def trigger_config_apply():
  """Trigger config apply script asynchronously."""
  try:subprocess.Popen([APPLY_SCRIPT]);return {"ok":True,"restarting":True}
  except Exception as e:return {"ok":False,"error":str(e)}

def verify_hmac_auth(timestamp_header, signature_header, method, path, body):
  """Verify HMAC-SHA256 signature for authenticated endpoints.

  Signature binds:
  - timestamp (replay protection)
  - HTTP method + path (prevents cross-endpoint replay/substitution)
  - request body (integrity)

  Message format:
    "{timestamp}.{method}.{path}.{body}" where body is UTF-8 JSON string.

  Returns:
    (bool, str|None): (success, error_message)
    - (True, None) on success
    - (False, error_message) on failure with reason
  """
  if not API_SECRET:
    return False, "API_SECRET not configured"
  if not timestamp_header:
    return False, "Missing X-Timestamp header"
  if not signature_header:
    return False, "Missing X-Signature header"

  # Parse and validate timestamp
  try:
    timestamp = int(timestamp_header)
  except ValueError:
    # Provide clear error for non-integer timestamps
    if '.' in str(timestamp_header):
      return False, f"Invalid timestamp format: '{timestamp_header}' (must be integer Unix epoch, not float)"
    else:
      return False, f"Invalid timestamp format: '{timestamp_header}' (expected integer Unix epoch, e.g., 1707676800)"

  # Check timestamp freshness (replay protection)
  now = int(time.time())
  age = now - timestamp
  if abs(age) > 300:
    if age > 0:
      return False, f"Timestamp expired: {abs(age)}s old (max 300s allowed)"
    else:
      return False, f"Timestamp from future: {abs(age)}s ahead (max 300s drift allowed)"

  # Verify signature
  try:
    b = body.decode('utf-8') if isinstance(body, (bytes, bytearray)) else (body or '')
    msg = f"{timestamp}.{method}.{path}.{b}"
    expected_sig = hmac.new(API_SECRET.encode(), msg.encode(), hashlib.sha256).hexdigest()
    if hmac.compare_digest(signature_header, expected_sig):
      return True, None
    else:
      return False, "Signature mismatch (check API_SECRET and message format)"
  except UnicodeDecodeError as e:
    return False, f"Body encoding error: {e}"
  except Exception as e:
    return False, f"Signature verification failed: {e}"

class H(http.server.BaseHTTPRequestHandler):
  def log_message(self,*a):pass
  
  def send_json(self,code,data):
    self.send_response(code);self.send_header('Content-type','application/json');self.end_headers()
    self.wfile.write(json.dumps(data).encode())
  
  def do_GET(self):
    if self.path=='/status':
      self.send_response(200);self.send_header('Content-type','application/json');self.end_headers();self.wfile.write(json.dumps(get_status()).encode())
    elif self.path=='/health':
      s=get_status();code=200 if s.get('bot_online') else 503;self.send_response(code);self.send_header('Content-type','application/json');self.end_headers();self.wfile.write(json.dumps({"healthy":s.get('bot_online',False),"phase":s.get('phase'),"desc":s.get('desc'),"safe_mode":s.get('safe_mode',False)}).encode())
    elif self.path=='/stages':
      timestamp=self.headers.get('X-Timestamp')
      signature=self.headers.get('X-Signature')
      # Require auth: stages/log/config may contain sensitive info
      ok,err=verify_hmac_auth(timestamp, signature, self.command, self.path, b'')
      if not ok:
        self.send_json(403,{"ok":False,"error":err or "Forbidden"});return
      self.send_response(200);self.send_header('Content-type','text/plain');self.end_headers()
      try:
        with open('/var/log/init-stages.log','r') as f:self.wfile.write(f.read().encode())
      except:self.wfile.write(b"No log")
    elif self.path=='/log':
      timestamp=self.headers.get('X-Timestamp')
      signature=self.headers.get('X-Signature')
      ok,err=verify_hmac_auth(timestamp, signature, self.command, self.path, b'')
      if not ok:
        self.send_json(403,{"ok":False,"error":err or "Forbidden"});return
      self.send_response(200);self.send_header('Content-type','text/plain');self.end_headers()
      # Include all relevant logs for debugging
      for lf in ['/var/log/bootstrap.log','/var/log/phase1.log','/var/log/phase2.log','/var/log/post-boot-check.log','/var/log/safe-mode-recovery.log','/var/log/cloud-init-output.log']:
        try:
          self.wfile.write(f"\n=== {lf} ===\n".encode())
          with open(lf,'r') as f:self.wfile.write(f.read()[-16384:].encode())  # Increased to 16KB
        except:self.wfile.write(f"  (not found)\n".encode())
      
      # Enhanced debug info for isolation issues
      self.wfile.write(b"\n=== FILE EXISTENCE CHECKS ===\n")
      for f in ['/etc/droplet.env','/etc/habitat-parsed.env','/etc/habitat.json','/etc/agents.json']:
        try:
          import stat
          st=os.stat(f)
          self.wfile.write(f"{f}: exists, size={st.st_size}, mode={oct(st.st_mode)}\n".encode())
        except:self.wfile.write(f"{f}: NOT FOUND\n".encode())
      
      self.wfile.write(b"\n=== /etc/habitat-parsed.env FULL CONTENTS (secrets redacted) ===\n")
      try:
        with open('/etc/habitat-parsed.env','r') as f:
          for line in f:
            # Redact sensitive lines
            if any(x in line.upper() for x in ['TOKEN','SECRET','KEY','PASSWORD']):
              key=line.split('=')[0] if '=' in line else line
              self.wfile.write(f"{key}=<REDACTED>\n".encode())
            else:
              self.wfile.write(line.encode())
      except Exception as e:
        self.wfile.write(f"ERROR reading habitat-parsed.env: {e}\n".encode())
      
      self.wfile.write(b"\n=== SYSTEMD SESSION SERVICE FILES ===\n")
      try:
        r=subprocess.run(['ls','-la','/etc/systemd/system/'],capture_output=True,timeout=5)
        for line in r.stdout.decode().split('\n'):
          if 'openclaw' in line:
            self.wfile.write(f"{line}\n".encode())
      except Exception as e:
        self.wfile.write(f"ERROR: {e}\n".encode())
      
      self.wfile.write(b"\n=== SESSION STATE DIRECTORIES ===\n")
      try:
        import glob
        # Get username from env
        username="bot"
        try:
          with open('/etc/habitat-parsed.env','r') as f:
            for line in f:
              if line.startswith('USERNAME='):
                username=line.split('=',1)[1].strip().strip('"')
                break
        except:pass
        state_base=f"/home/{username}/.openclaw-sessions"
        self.wfile.write(f"State base: {state_base}\n".encode())
        if os.path.exists(state_base):
          r=subprocess.run(['ls','-laR',state_base],capture_output=True,timeout=5)
          self.wfile.write(r.stdout[-4096:])
        else:
          self.wfile.write(b"State directory does not exist yet\n")
      except Exception as e:
        self.wfile.write(f"ERROR: {e}\n".encode())
      
      self.wfile.write(b"\n=== SESSION SERVICE STATUS ===\n")
      for svc in ['clawdbot','openclaw-browser','openclaw-documents','openclaw-containers']:
        try:
          r=subprocess.run(['systemctl','status',svc,'--no-pager'],capture_output=True,timeout=5)
          self.wfile.write(f"\n--- {svc} ---\n".encode())
          self.wfile.write(r.stdout[-2048:])
        except Exception as e:
          self.wfile.write(f"{svc}: error getting status: {e}\n".encode())
      
      self.wfile.write(b"\n=== SESSION SERVICE LOGS (journalctl) ===\n")
      try:
        r=subprocess.run(['journalctl','-u','openclaw-browser','-u','openclaw-documents','-u','openclaw-containers','--since','30 min ago','-n','100','--no-pager'],capture_output=True,timeout=10)
        self.wfile.write(r.stdout[-8192:])
      except Exception as e:
        self.wfile.write(f"ERROR: {e}\n".encode())
      
      self.wfile.write(b"\n=== CLAWDBOT LOGS ===\n")
      try:
        r=subprocess.run(['journalctl','-u','clawdbot','--since','30 min ago','-n','50','--no-pager'],capture_output=True,timeout=10)
        self.wfile.write(r.stdout[-4096:])
      except Exception as e:
        self.wfile.write(f"ERROR: {e}\n".encode())
      
      self.wfile.write(b"\n=== INIT STATUS FILES ===\n")
      for f in ['/var/lib/init-status/stage','/var/lib/init-status/phase','/var/lib/init-status/setup-complete','/var/lib/init-status/safe-mode','/var/lib/init-status/needs-post-boot-check']:
        try:
          if os.path.exists(f):
            with open(f,'r') as fh:
              content=fh.read().strip()[:100]
            self.wfile.write(f"{f}: exists, content='{content}'\n".encode())
          else:
            self.wfile.write(f"{f}: NOT FOUND\n".encode())
        except Exception as e:
          self.wfile.write(f"{f}: error: {e}\n".encode())
    elif self.path=='/config/status':
      # Unauthenticated endpoint - returns only api_uploaded status (no sensitive data)
      self.send_json(200,get_config_upload_status())
    elif self.path=='/config':
      timestamp=self.headers.get('X-Timestamp')
      signature=self.headers.get('X-Signature')
      ok,err=verify_hmac_auth(timestamp, signature, self.command, self.path, b'')
      if not ok:
        self.send_json(403,{"ok":False,"error":err or "Forbidden"});return
      self.send_json(200,get_config_status())
    else:self.send_response(404);self.end_headers()
  
  def do_POST(self):
    content_length=int(self.headers.get('Content-Length',0))
    body=self.rfile.read(content_length) if content_length else b'{}'
    
    if self.path=='/sync':
      timestamp=self.headers.get('X-Timestamp')
      signature=self.headers.get('X-Signature')
      ok,err=verify_hmac_auth(timestamp, signature, self.command, self.path, body)
      if not ok:
        self.send_json(403,{"ok":False,"error":err or "Forbidden"});return
      
      self.send_response(200);self.send_header('Content-type','application/json');self.end_headers()
      try:r=subprocess.run(["/usr/local/bin/sync-openclaw-state.sh"],capture_output=True,timeout=60);self.wfile.write(json.dumps({"ok":r.returncode==0}).encode())
      except Exception as x:self.wfile.write(json.dumps({"ok":False,"error":str(x)}).encode())
    
    elif self.path=='/prepare-shutdown':
      timestamp=self.headers.get('X-Timestamp')
      signature=self.headers.get('X-Signature')
      ok,err=verify_hmac_auth(timestamp, signature, self.command, self.path, body)
      if not ok:
        self.send_json(403,{"ok":False,"error":err or "Forbidden"});return
      
      self.send_response(200);self.send_header('Content-type','application/json');self.end_headers()
      try:subprocess.run(["/usr/local/bin/sync-openclaw-state.sh"],timeout=60);subprocess.run(["systemctl","stop","clawdbot"],timeout=30);self.wfile.write(json.dumps({"ok":True,"ready_for_shutdown":True}).encode())
      except Exception as x:self.wfile.write(json.dumps({"ok":False,"error":str(x)}).encode())
    
    elif self.path=='/keepalive':
      timestamp=self.headers.get('X-Timestamp')
      signature=self.headers.get('X-Signature')
      ok,err=verify_hmac_auth(timestamp, signature, self.command, self.path, body)
      if not ok:
        self.send_json(403,{"ok":False,"error":err or "Forbidden"});return
      
      try:
        subprocess.run(["systemctl","stop","self-destruct.timer","self-destruct.service"],capture_output=True,timeout=10)
        subprocess.run(["systemctl","reset-failed","self-destruct.timer"],capture_output=True,timeout=10)
        subprocess.run(["/usr/local/bin/schedule-destruct.sh"],check=True,capture_output=True,timeout=30)
        self.send_json(200,{"ok":True})
      except Exception as e:
        self.send_json(500,{"ok":False,"error":str(e)})
    
    elif self.path=='/config/upload':
      timestamp=self.headers.get('X-Timestamp')
      signature=self.headers.get('X-Signature')
      content_type=self.headers.get('Content-Type','')
      
      # Support base64-encoded body (for iOS Shortcuts - avoids shell escaping issues)
      if 'base64' in content_type.lower():
        try:
          # Strip whitespace (iOS may line-wrap at 76 chars)
          body=base64.b64decode(body.replace(b'\n',b'').replace(b'\r',b'').replace(b' ',b''))
        except Exception as e:
          self.send_json(400,{"ok":False,"error":f"Invalid base64: {e}"});return
      
      ok,err=verify_hmac_auth(timestamp, signature, self.command, self.path, body)
      if not ok:
        self.send_json(403,{"ok":False,"error":err or "Forbidden"});return
      
      try:
        data=json.loads(body)
      except json.JSONDecodeError as e:
        self.send_json(400,{"ok":False,"error":f"Invalid JSON: {e}"});return
      
      errors=validate_config_upload(data)
      if errors:
        self.send_json(400,{"ok":False,"errors":errors});return
      
      files_written=[]
      
      # Merge globals into existing habitat on disk
      # Flow: YAML embeds minimal habitat → Shortcut sends globals to merge
      if "globals" in data:
        globals_data = data["globals"]
        if isinstance(globals_data, dict):
          # Read existing habitat from disk
          try:
            with open(HABITAT_PATH, 'r') as f:
              habitat = json.load(f)
          except FileNotFoundError:
            self.send_json(400,{"ok":False,"error":"No existing habitat.json to merge globals into"});return
          except json.JSONDecodeError as e:
            self.send_json(500,{"ok":False,"error":f"Existing habitat.json is invalid: {e}"});return
          
          # Merge globals into habitat (globals don't overwrite existing keys)
          for key, value in globals_data.items():
            if key not in habitat:
              habitat[key] = value
          
          # Write merged habitat back
          result=write_config_file(HABITAT_PATH, habitat)
          if not result["ok"]:
            self.send_json(500,{"ok":False,"error":f"Failed to write merged habitat: {result.get('error')}"});return
          files_written.append(HABITAT_PATH + " (merged)")
      
      # Write habitat config (if provided directly, overwrites)
      elif "habitat" in data:
        result=write_config_file(HABITAT_PATH,data["habitat"])
        if not result["ok"]:
          self.send_json(500,{"ok":False,"error":f"Failed to write habitat: {result.get('error')}"});return
        files_written.append(HABITAT_PATH)
      
      # Write agents library
      if "agents" in data:
        result=write_config_file(AGENTS_PATH,data["agents"])
        if not result["ok"]:
          self.send_json(500,{"ok":False,"error":f"Failed to write agents: {result.get('error')}"});return
        files_written.append(AGENTS_PATH)
      
      # Merge globals into existing habitat (for two-phase provisioning)
      merged_fields=[]
      if "globals" in data:
        result=merge_globals_into_habitat(data["globals"])
        if not result["ok"]:
          self.send_json(500,{"ok":False,"error":f"Failed to merge globals: {result.get('error')}"});return
        merged_fields=result.get("merged_fields",[])
        files_written.append(f"{HABITAT_PATH} (merged: {', '.join(merged_fields)})")
      
      # Write upload marker if any files were written
      if files_written or merged_fields:
        write_upload_marker()
      
      # Apply if requested
      applied=False
      if data.get("apply"):
        apply_result=trigger_config_apply()
        if not apply_result["ok"]:
          self.send_json(500,{"ok":False,"error":f"Failed to apply: {apply_result.get('error')}","files_written":files_written});return
        applied=True
      
      self.send_json(200,{"ok":True,"files_written":files_written,"applied":applied})
    
    elif self.path=='/config/apply':
      timestamp=self.headers.get('X-Timestamp')
      signature=self.headers.get('X-Signature')
      ok,err=verify_hmac_auth(timestamp, signature, self.command, self.path, body)
      if not ok:
        self.send_json(403,{"ok":False,"error":err or "Forbidden"});return
      
      result=trigger_config_apply()
      self.send_json(200 if result["ok"] else 500,result)
    
    else:
      self.send_response(404);self.end_headers()

class R(socketserver.TCPServer):allow_reuse_address=True
if __name__=='__main__':
  # SECURITY MODEL:
  # - Default: 127.0.0.1 (localhost only, secure-by-default)
  # - Enable remote access: set remoteApi: true in habitat config
  # - Advanced override: apiBindAddress in habitat (takes precedence)
  # - /status, /health: Public (read-only, no secrets, needed for polling)
  # - /stages, /log, /config: HMAC auth required (may contain sensitive info)
  # - /config/upload, /config/apply: HMAC auth required (mutation endpoints)
  bind_addr = API_BIND_ADDRESS if API_BIND_ADDRESS != '0.0.0.0' else ''
  print(f"[api-server] Starting on {API_BIND_ADDRESS}:{PORT}")
  with R((bind_addr,PORT),H) as h:h.serve_forever()
