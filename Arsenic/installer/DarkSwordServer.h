//
//  DarkSwordServer.h
//  Arsenic
//
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void start_darksword_server(void);
void stop_darksword_server(void);
BOOL is_darksword_server_running(void);

#ifdef __cplusplus
}
#endif