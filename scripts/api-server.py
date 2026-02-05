#!/usr/bin/env python3
# =============================================================================
# api-server.py -- Droplet Status API (HTTP server on port 8080)
# =============================================================================
# Purpose:  Lightweight HTTP API exposing droplet provisioning status.
#           Provides /status, /health, /stages (GET) and /sync,
#           /prepare-shutdown (POST) endpoints.
#
# Endpoints:
#   GET  /status  -- Full status JSON (phase, stage, services, safe_mode)
#   GET  /health  -- Health check (200 if bot online, 503 if not)
#   GET  /stages  -- Raw init-stages.log text
#   POST /sync    -- Trigger clawdbot state sync to Dropbox
#   POST /prepare-shutdown -- Sync state and stop clawdbot for shutdown
#
# Dependencies: systemctl, /usr/local/bin/sync-clawdbot-state.sh
#
# Original: /usr/local/bin/api-server.py (in hatch.yaml write_files)
# =============================================================================
import http.server,socketserver,subprocess,json,os,base64
PORT=8080
P1_STAGES={0:"init",1:"preparing",2:"installing-bot",3:"bot-online"}
P2_STAGES={4:"desktop-environment",5:"developer-tools",6:"browser-tools",7:"desktop-services",8:"skills-apps",9:"remote-access",10:"finalizing",11:"ready"}
def check_service(name):
  try:r=subprocess.run(["systemctl","is-active",name],capture_output=True,timeout=5);return r.stdout.decode().strip()=="active"
  except:return False
def get_status():
  s,p=0,1
  try:
    with open('/var/lib/init-status/stage','r') as f:s=int(f.read().strip())
    with open('/var/lib/init-status/phase','r') as f:p=int(f.read().strip())
  except:pass
  p1_done=os.path.exists('/var/lib/init-status/phase1-complete')
  p2_done=os.path.exists('/var/lib/init-status/phase2-complete')
  setup_done=os.path.exists('/var/lib/init-status/setup-complete')
  bot_online=check_service('clawdbot')
  svc={}
  if p2_done or setup_done:
    for sv in ['clawdbot','xrdp','desktop','x11vnc']:svc[sv]=check_service(sv)
  desc=P1_STAGES.get(s) if p==1 else P2_STAGES.get(s,f"stage-{s}")
  safe_mode=os.path.exists('/var/lib/init-status/safe-mode')
  return {"phase":p,"stage":s,"desc":desc,"bot_online":bot_online,"phase1_complete":p1_done,"phase2_complete":p2_done,"ready":setup_done and bot_online,"safe_mode":safe_mode,"services":svc if svc else None}
class H(http.server.BaseHTTPRequestHandler):
  def log_message(self,*a):pass
  def do_GET(self):
    if self.path=='/status':
      self.send_response(200);self.send_header('Content-type','application/json');self.end_headers();self.wfile.write(json.dumps(get_status()).encode())
    elif self.path=='/health':
      s=get_status();code=200 if s.get('bot_online') else 503;self.send_response(code);self.send_header('Content-type','application/json');self.end_headers();self.wfile.write(json.dumps({"healthy":s.get('bot_online',False),"phase":s.get('phase'),"desc":s.get('desc'),"safe_mode":s.get('safe_mode',False)}).encode())
    elif self.path=='/stages':
      self.send_response(200);self.send_header('Content-type','text/plain');self.end_headers()
      try:
        with open('/var/log/init-stages.log','r') as f:self.wfile.write(f.read().encode())
      except:self.wfile.write(b"No log")
    elif self.path=='/log':
      self.send_response(200);self.send_header('Content-type','text/plain');self.end_headers()
      for lf in ['/var/log/bootstrap.log','/var/log/phase1.log','/var/log/phase2.log','/var/log/cloud-init-output.log']:
        try:
          self.wfile.write(f"\n=== {lf} ===\n".encode())
          with open(lf,'r') as f:self.wfile.write(f.read()[-8192:].encode())
        except:self.wfile.write(f"  (not found)\n".encode())
    else:self.send_response(404);self.end_headers()
  def do_POST(self):
    if self.path=='/sync':
      self.send_response(200);self.send_header('Content-type','application/json');self.end_headers()
      try:r=subprocess.run("/usr/local/bin/sync-clawdbot-state.sh",shell=True,capture_output=True,timeout=60);self.wfile.write(json.dumps({"ok":r.returncode==0}).encode())
      except Exception as x:self.wfile.write(json.dumps({"ok":False,"error":str(x)}).encode())
    elif self.path=='/prepare-shutdown':
      self.send_response(200);self.send_header('Content-type','application/json');self.end_headers()
      try:subprocess.run("/usr/local/bin/sync-clawdbot-state.sh",shell=True,timeout=60);subprocess.run("systemctl stop clawdbot",shell=True,timeout=30);self.wfile.write(json.dumps({"ok":True,"ready_for_shutdown":True}).encode())
      except Exception as x:self.wfile.write(json.dumps({"ok":False,"error":str(x)}).encode())
    else:self.send_response(404);self.end_headers()
class R(socketserver.TCPServer):allow_reuse_address=True
with R(("",PORT),H) as h:h.serve_forever()
