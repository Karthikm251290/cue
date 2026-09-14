#include "CPlatform.h"
#include <libproc.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <IOKit/hid/IOHIDManager.h>
int sc_process(int pid, SCProcess *r) {
 struct proc_bsdinfo p;
 if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &p, sizeof(p)) != sizeof(p)) return 0;
 memset(r,0,sizeof(*r)); r->pid=pid; r->parent=p.pbi_ppid;
 r->started=p.pbi_start_tvsec*1000000ULL+p.pbi_start_tvusec; r->terminal=p.e_tdev;
 strlcpy(r->name,p.pbi_name,sizeof(r->name));
 const char *tty=devname(p.e_tdev,S_IFCHR);if(tty)snprintf(r->tty,sizeof(r->tty),"/dev/%s",tty); return 1;
}
typedef struct {IOHIDManagerRef manager; IOHIDDeviceRef device; SCKeyCallback callback; void *context; uint8_t input[1024]; uint8_t keys[32]; int connected;} Deck;
static void input(void *ctx, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex length) {
 Deck *d=ctx; if(result!=kIOReturnSuccess || length<36) return;
 for(int i=0;i<32;i++) {uint8_t down=report[i+4]!=0; if(d->keys[i]!=down){d->keys[i]=down;d->callback(d->context,i,down);}}
}
static void removed(void *ctx, IOReturn result, void *sender) {((Deck*)ctx)->connected=0;}
void *sc_deck_open(SCKeyCallback cb, void *ctx, int *error) {
 Deck *d=calloc(1,sizeof(Deck)); d->callback=cb;d->context=ctx;
 d->manager=IOHIDManagerCreate(kCFAllocatorDefault,kIOHIDOptionsTypeNone);
 int vendor=0x0fd9; CFNumberRef v=CFNumberCreate(NULL,kCFNumberIntType,&vendor);
 const void *keys[]={CFSTR(kIOHIDVendorIDKey)};const void *values[]={v};
 CFDictionaryRef match=CFDictionaryCreate(NULL,keys,values,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 IOHIDManagerSetDeviceMatching(d->manager,match);CFRelease(match);CFRelease(v);
 CFSetRef devices=IOHIDManagerCopyDevices(d->manager);
 if(devices){ CFIndex n=CFSetGetCount(devices); const void **list=calloc(n,sizeof(void*));CFSetGetValues(devices,list);
 for(CFIndex i=0;i<n;i++){IOHIDDeviceRef dev=(IOHIDDeviceRef)list[i]; int product=0;CFTypeRef p=IOHIDDeviceGetProperty(dev,CFSTR(kIOHIDProductIDKey));if(p) CFNumberGetValue(p,kCFNumberIntType,&product);if(product==0x006c || product==0x008f){d->device=dev;CFRetain(dev);break;}}
 free(list); CFRelease(devices);}
 if(!d->device){*error=-1;sc_deck_close(d);return NULL;}
 IOReturn r=IOHIDDeviceOpen(d->device,kIOHIDOptionsTypeSeizeDevice);
 if(r!=kIOReturnSuccess){*error=r;sc_deck_close(d);return NULL;}
 d->connected=1;
 IOHIDDeviceRegisterInputReportCallback(d->device,d->input,sizeof(d->input),input,d);
 IOHIDDeviceRegisterRemovalCallback(d->device,removed,d);
 IOHIDDeviceScheduleWithRunLoop(d->device,CFRunLoopGetMain(),kCFRunLoopCommonModes);
 *error=0;return d;
}
int sc_deck_image(void *ptr,int key,const unsigned char *bytes,int length){
 Deck *d=ptr;if(!d || !d->connected || key<0 || key>=32)return -1;
 for(int offset=0,page=0;offset<length;page++){
  uint8_t report[1024]={0};int n=length-offset;if(n>1016)n=1016;
  report[0]=2;report[1]=7;report[2]=key;report[3]=(offset+n==length);report[4]=n&255;report[5]=n>>8;report[6]=page&255;report[7]=page>>8;
  memcpy(report+8,bytes+offset,n);
  IOReturn r=IOHIDDeviceSetReport(d->device,kIOHIDReportTypeOutput,2,report,sizeof(report));if(r!=kIOReturnSuccess)return r;offset+=n;
 }return 0;
}
int sc_deck_brightness(void *ptr,int b){Deck*d=ptr;if(!d || !d->connected)return -1;uint8_t r[32]={3,8,(uint8_t)b};return IOHIDDeviceSetReport(d->device,kIOHIDReportTypeFeature,3,r,sizeof(r));}
int sc_deck_connected(void *ptr){return ptr?((Deck*)ptr)->connected:0;}
void sc_deck_close(void *ptr){Deck*d=ptr;if(!d)return;if(d->device){IOHIDDeviceUnscheduleFromRunLoop(d->device,CFRunLoopGetMain(),kCFRunLoopCommonModes);IOHIDDeviceClose(d->device,kIOHIDOptionsTypeNone);CFRelease(d->device);}if(d->manager)CFRelease(d->manager);free(d);}
