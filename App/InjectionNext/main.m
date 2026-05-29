//
//  main.m
//  InjectionIII
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//

#import <Cocoa/Cocoa.h>

extern int InjectionNextCommandMain(int argc, const char * argv[]);

int main(int argc, const char * argv[]) {
    if (argc > 1 && strcmp(argv[1], "serve") == 0) {
        return InjectionNextCommandMain(argc, argv);
    }
    return NSApplicationMain(argc, argv);
}
