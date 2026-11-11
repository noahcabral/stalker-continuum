#pragma once

#include "WeaponShotgun.h"

class CWeaponBM16 : public CWeaponShotgun
{
    typedef CWeaponShotgun inherited;

public:
    virtual ~CWeaponBM16();
    virtual void Load(LPCSTR section);

protected:
    virtual void PlayAnimShoot();
    virtual void PlayAnimReload();
    virtual void PlayReloadSound();
    virtual void PlayAnimIdle();
    virtual void PlayAnimIdleMoving();
    virtual void PlayAnimIdleSprint();
    pcstr IwpSprintVariant() const override
    {
        static constexpr pcstr variants[]{"_0", "_1", "_2"};
        return variants[std::min(m_magazine.size(), size_t(2))];
    }
    virtual void PlayAnimShow();
    virtual void PlayAnimHide();
    virtual void PlayAnimBore();

private:
    DECLARE_SCRIPT_REGISTER_FUNCTION(CWeaponShotgun);
};
