#include <gbm.h>
#include <fcntl.h>
#include <stdio.h>
#include <time.h>
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e3+t.tv_nsec/1e6;}
int main(void){double t0=now();int fd=open("/dev/dri/renderD128",O_RDWR);struct gbm_device*d=gbm_create_device(fd);double t1=now();
struct gbm_bo*bo=gbm_bo_create(d,1920,1200,GBM_FORMAT_XRGB8888,GBM_BO_USE_SCANOUT|GBM_BO_USE_LINEAR);double t2=now();
printf("gbm_create_device %.2f ms, first bo %.2f ms (%s)\n",t1-t0,t2-t1,gbm_device_get_backend_name(d));return bo==0;}
