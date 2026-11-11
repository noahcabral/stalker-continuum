#pragma once

#include "xrEngine/xr_level_controller.h"

namespace ScriptLevelEffects
{
constexpr u32 HideMinimap = 1u << 14;

void SetActionBlocked(EGameActions action, bool blocked);
bool IsActionBlocked(EGameActions action);
void SetElectronicInterference(float flashlight, float flicker, float lights);
float LightIntensity(bool flashlight);
void Reset();
}
