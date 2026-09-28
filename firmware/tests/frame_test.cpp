#include "../src/frame.h"
#include <assert.h>
#include <stdio.h>
int main() {
    uint8_t p[20] = {1,1,42,0,0,0,1};
    assert(bridge::validFrame(p,20,false,0,0));
    assert(!bridge::validFrame(p,19,false,0,0));
    assert(!bridge::validFrame(p,20,true,42,1));
    p[6]=2; p[10]=1; p[12]=26;
    assert(bridge::validFrame(p,20,true,42,1));
    assert(!bridge::validFrame(p,20,false,0,0));
    assert(!bridge::validFrame(p,20,true,43,1));
    p[10]=0; assert(!bridge::validFrame(p,20,true,42,1));
    p[12]=0; assert(bridge::validFrame(p,20,true,42,1));
    p[18]=1; assert(!bridge::validFrame(p,20,true,42,1));
    p[18]=0; p[1]=2; assert(!bridge::validFrame(p,20,true,42,1));
    puts("PASS: firmware frame validation, release invariant, session and replay rejection");
}
