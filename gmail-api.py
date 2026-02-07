#!/usr/bin/env python3
import argparse,base64,os,sys,mimetypes
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from email.mime.base import MIMEBase
from email import encoders
try:
  from google.oauth2.credentials import Credentials
  from googleapiclient.discovery import build
except ImportError:
  sys.exit("Run: pip3 install google-auth google-api-python-client")
def get_creds():
  cid,csc,rtk=os.environ.get('GMAIL_CLIENT_ID'),os.environ.get('GMAIL_CLIENT_SECRET'),os.environ.get('GMAIL_REFRESH_TOKEN')
  if not all([cid,csc,rtk]):
    for envf in [os.path.expanduser('~/.openclaw/.env'),'/etc/droplet.env']:
      try:
        with open(envf,'r') as f:
          for l in f:
            l=l.strip()
            if l.startswith('GMAIL_CLIENT_ID='):cid=cid or l.split('=',1)[1].strip('"')
            elif l.startswith('GMAIL_CLIENT_SECRET='):csc=csc or l.split('=',1)[1].strip('"')
            elif l.startswith('GMAIL_REFRESH_TOKEN='):rtk=rtk or l.split('=',1)[1].strip('"')
            elif l.startswith('GMAIL_CLIENT_ID_B64='):v=l.split('=',1)[1].strip('"');cid=cid or (base64.b64decode(v).decode() if v else None)
            elif l.startswith('GMAIL_CLIENT_SECRET_B64='):v=l.split('=',1)[1].strip('"');csc=csc or (base64.b64decode(v).decode() if v else None)
            elif l.startswith('GMAIL_REFRESH_TOKEN_B64='):v=l.split('=',1)[1].strip('"');rtk=rtk or (base64.b64decode(v).decode() if v else None)
      except:pass
      if all([cid,csc,rtk]):break
  if not all([cid,csc,rtk]):sys.exit("Gmail API credentials not configured")
  return Credentials(None,refresh_token=rtk,token_uri="https://oauth2.googleapis.com/token",client_id=cid,client_secret=csc)
def cmd_send(args):
  svc=build('gmail','v1',credentials=get_creds(),cache_discovery=False)
  msg=MIMEMultipart('mixed');msg['To']=args.to;msg['Subject']=args.subject
  if args.cc:msg['Cc']=args.cc
  msg.attach(MIMEText(args.body,'html' if args.html else 'plain'))
  if args.attach:
    for fp in args.attach:
      if os.path.isfile(fp):
        ct,_=mimetypes.guess_type(fp);ct=ct or 'application/octet-stream';mt,st=ct.split('/',1)
        with open(fp,'rb') as f:
          part=MIMEBase(mt,st);part.set_payload(f.read());encoders.encode_base64(part)
        part.add_header('Content-Disposition','attachment',filename=os.path.basename(fp));msg.attach(part)
  r=svc.users().messages().send(userId='me',body={'raw':base64.urlsafe_b64encode(msg.as_bytes()).decode()}).execute()
  print(f"Sent to {args.to} (ID: {r['id']})")
def cmd_list(args):
  svc=build('gmail','v1',credentials=get_creds(),cache_discovery=False)
  res=svc.users().messages().list(userId='me',maxResults=args.n,q=args.q or '').execute()
  for msg in res.get('messages',[]):
    m=svc.users().messages().get(userId='me',id=msg['id'],format='metadata',metadataHeaders=['From','Subject','Date']).execute()
    h={x['name']:x['value'] for x in m['payload']['headers']}
    print(f"ID: {msg['id']}\n  From: {h.get('From','?')}\n  Subject: {h.get('Subject','(no subject)')}\n  Date: {h.get('Date','?')}\n")
def cmd_read(args):
  svc=build('gmail','v1',credentials=get_creds(),cache_discovery=False)
  m=svc.users().messages().get(userId='me',id=args.id,format='full').execute()
  h={x['name']:x['value'] for x in m['payload']['headers']}
  print(f"From: {h.get('From','?')}\nTo: {h.get('To','?')}\nSubject: {h.get('Subject','?')}\nDate: {h.get('Date','?')}\n{'='*60}")
  def get_body(pl):
    if 'body' in pl and pl['body'].get('data'):return base64.urlsafe_b64decode(pl['body']['data']).decode('utf-8',errors='replace')
    if 'parts' in pl:
      for p in pl['parts']:
        if p.get('filename'):continue
        if p['mimeType']=='text/plain' and p['body'].get('data'):return base64.urlsafe_b64decode(p['body']['data']).decode('utf-8',errors='replace')
        if 'parts' in p:
          r=get_body(p);
          if r:return r
    return None
  print(get_body(m['payload']) or "(Could not extract body)")
def main():
  p=argparse.ArgumentParser();sub=p.add_subparsers(dest='cmd',required=True)
  ps=sub.add_parser('send');ps.add_argument('to');ps.add_argument('subject');ps.add_argument('body');ps.add_argument('--html',action='store_true');ps.add_argument('--cc');ps.add_argument('--attach','-a',action='append')
  pl=sub.add_parser('list');pl.add_argument('-n',type=int,default=10);pl.add_argument('-q',default='')
  pr=sub.add_parser('read');pr.add_argument('id')
  args=p.parse_args();{'send':cmd_send,'list':cmd_list,'read':cmd_read}[args.cmd](args)
if __name__=='__main__':main()
