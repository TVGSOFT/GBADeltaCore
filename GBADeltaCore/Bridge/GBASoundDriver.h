//
//  GBASoundDriver.h
//  GBADeltaCore
//
//  Created by Riley Testut on 6/3/16.
//  Copyright © 2016 Riley Testut. All rights reserved.
//

#include <stdio.h>

#include "core/base/sound_driver.h"

class GBASoundDriver : public SoundDriver
{
public:
    GBASoundDriver();
    virtual ~GBASoundDriver();
    
    bool init(long sampleRate) override;
    void pause() override;
    void reset() override;
    void resume() override;
    void write(uint16_t *finalWave, int length) override;
    void setThrottle(unsigned short throttle) override;
};
