//
//  notweafications.h
//  RemoteCall notifications coloring
//

#ifndef notweafications_h
#define notweafications_h

#include <stdbool.h>

bool notweafications_apply_in_session(void);
bool notweafications_stop_in_session(void);
void notweafications_forget_remote_state(void);

#endif /* notweafications_h */