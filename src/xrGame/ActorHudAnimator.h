#pragma once

class CActor;
class CHudItem;

namespace ActorHudAnimator
{
bool Start(CActor* actor, pcstr section, u16 itemId = u16(-1),
    pcstr motion = "anm_show", void (*onComplete)() = nullptr);
void Stop(const CActor* actor);
void Destroy(const CActor* actor);
void Update(CActor* actor);
bool Active(const CActor* actor);
CActor* OwnerFor(const CHudItem* item);
pcstr Section(const CActor* actor);
u16 RestoredSlot(const CActor* actor);
bool BlocksAction(const CActor* actor, int action);
bool CommittingItem(const CActor* actor);
}
