#include "stdafx.h"

#include "SoundRender_CoreA.h"

XRSOUND_API u32 snd_device_id = u32(-1);

ISoundScene* DefaultSoundScene{};

namespace
{
// Dedicated simulation still needs sound metadata, timing and AI hearing
// events. No hardware targets means all emitters stay virtual.
class DedicatedSoundCore final : public CSoundRender_Core
{
public:
    using CSoundRender_Core::CSoundRender_Core;
    void _initialize_devices_list() override {}
    void _initialize() override { CSoundRender_Core::_initialize(); }
    void _clear() override { CSoundRender_Core::_clear(); }
    void set_master_volume(float) override {}
};
}

void CSoundManager::CreateDevicesList()
{
    ZoneScoped;

    if (GEnv.isDedicatedServer)
        SoundRender = xr_new<DedicatedSoundCore>(*this);
    else
    {
        SoundRender = xr_new<CSoundRender_CoreA>(*this);
        if (!strstr(Core.Params, "-nosound"))
            SoundRender->_initialize_devices_list();
    }

    if (!SoundRender->bPresent)
        soundDevices.emplace_back(nullptr, -1);

    GEnv.Sound = SoundRender;
}

void CSoundManager::Create()
{
    ZoneScoped;

    if (GEnv.isDedicatedServer || SoundRender->bPresent)
    {
        env_load();
        SoundRender->_initialize();
    }
}

void CSoundManager::Destroy()
{
    ZoneScoped;

    GEnv.Sound = nullptr;

    SoundRender->_clear();
    xr_delete(SoundRender);

    env_unload();

    for (auto& token : soundDevices)
    {
        pstr tokenName = const_cast<pstr>(token.name);
        xr_free(tokenName);
    }
    soundDevices.clear();
}

bool CSoundManager::IsSoundEnabled() const
{
    return SoundRender && SoundRender->bPresent;
}

void CSoundManager::env_load()
{
    string_path fn;
    if (FS.exist(fn, "$game_data$", SNDENV_FILENAME))
    {
        soundEnvironment = xr_new<SoundEnvironment_LIB>();
        soundEnvironment->Load(fn);
    }
}

void CSoundManager::env_unload()
{
    if (soundEnvironment)
        soundEnvironment->Unload();
    xr_delete(soundEnvironment);
}

SoundEnvironment_LIB* CSoundManager::get_env_library() const
{
    return soundEnvironment;
}

void CSoundManager::refresh_env_library()
{
    env_unload();
    env_load();
    SoundRender->env_apply();
}
