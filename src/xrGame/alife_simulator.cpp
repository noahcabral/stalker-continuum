////////////////////////////////////////////////////////////////////////////
//  Module      : alife_simulator.cpp
//  Created     : 25.12.2002
//  Modified    : 13.05.2004
//  Author      : Dmitriy Iassenev
//  Description : ALife Simulator
////////////////////////////////////////////////////////////////////////////

#include "pch_script.h"
#include "alife_simulator.h"
#include "xrServer_Objects_ALife.h"
#include "ai_space.h"
#include "xrEngine/IGame_Persistent.h"
#include "xrScriptEngine/script_engine.hpp"
#include "MainMenu.h"
#include "object_factory.h"
#include "alife_object_registry.h"
#include "alife_graph_registry.h"
#include "xrServer.h"
#include "xrServer_Objects_ALife_Monsters.h"
#include "Actor.h"
#include "Level.h"
#include "xrEngine/XR_IOConsole.h"

#ifdef DEBUG
#include "moving_objects.h"
#endif // DEBUG

LPCSTR alife_section = "alife";

float CALifeSimulator::DistanceToActivePlayers(const Fvector& position)
{
    const auto* campaignActor = graph().actor();
    if (psNET_direct_connect)
        return campaignActor->o_Position.distance_to(position);

    float nearest = flt_max;
    auto visit = [&](IClient* connection)
    {
        const auto* client = static_cast<const xrClientData*>(connection);
        if (!client->owner || !client->net_Ready ||
            !client->owner->s_flags.test(M_SPAWN_OBJECT_CAMPAIGN_PLAYER))
            return;

        auto* object = smart_cast<CGameObject*>(Level().Objects.net_Find(client->owner->ID));
        const auto* actor = object ? object->cast_actor() : nullptr;
        if (actor && actor->g_Alive())
            nearest = std::min(nearest, actor->Position().distance_to(position));
    };
    server().ForEachClientDo(visit);
    return nearest != flt_max ? nearest : campaignActor->o_Position.distance_to(position);
}


CALifeSimulator::CALifeSimulator(IPureServer* server, shared_str* command_line)
    : CALifeSimulatorBase(server, alife_section), CALifeUpdateManager(server, alife_section),
      CALifeInteractionManager(server, alife_section)
{
    // XXX: why do we need to reinitialize script engine?
    if (!strstr(Core.Params, "-keep_lua"))
    {
        ai().RestartScriptEngine();
    }

    ai().set_alife(this);

    setup_command_line(command_line);

    typedef IGame_Persistent::params params;
    params& p = g_pGamePersistent->m_game_params;

    R_ASSERT2(xr_strlen(p.m_game_or_spawn) && !xr_strcmp(p.m_alife, "alife") && !xr_strcmp(p.m_game_type, "single"),
        "Invalid server options!");

    // The first four fields select the save, mode, simulator, and startup action.
    // Preserve the trailing session settings when the simulator consumes the action.
    const char* networkOptions = command_line->c_str();
    for (int field = 0; field < 4 && networkOptions; ++field)
        networkOptions = strchr(networkOptions + (field != 0), '/');

    xr_string session = p.m_game_or_spawn;
    session += "/";
    session += p.m_game_type;
    session += "/";
    session += p.m_alife;
    if (networkOptions)
        session += networkOptions;
    *command_line = session.c_str();

    const bool isNewGame = xr_strcmp(p.m_new_or_load, "new") != -1;

    LPCSTR start_game_callback = pSettings->r_string(alife_section, "start_game_callback");
    luabind::functor<void> functor;
    R_ASSERT2(GEnv.ScriptEngine->functor(start_game_callback, functor), "failed to get start game callback");
    functor(isNewGame);

    load(p.m_game_or_spawn, !xr_strcmp(p.m_new_or_load, "load") ? false : true, !xr_strcmp(p.m_new_or_load, "new"));
}

CALifeSimulator::~CALifeSimulator()
{
    VERIFY(!ai().get_alife());

    configs_type::iterator i = m_configs_lru.begin();
    configs_type::iterator const e = m_configs_lru.end();
    for (; i != e; ++i)
        FS.r_close((*i).second);
}

void CALifeSimulator::destroy()
{
    //  validate                    ();
    CALifeUpdateManager::destroy();
    VERIFY(ai().get_alife());
    ai().set_alife(0);
}

void CALifeSimulator::setup_simulator(CSE_ALifeObject* object)
{
    //  VERIFY2                     (!object->m_alife_simulator,object->s_name_replace);
    object->m_alife_simulator = this;
}

void CALifeSimulator::reload(LPCSTR section) { CALifeUpdateManager::reload(section); }
struct string_prdicate
{
    shared_str m_value;

    inline string_prdicate(shared_str const& value) : m_value(value) {}
    inline bool operator()(std::pair<shared_str, IReader*> const& value) const
    {
        return !xr_strcmp(m_value, value.first);
    }
}; // struct string_prdicate

IReader const* CALifeSimulator::get_config(shared_str config) const
{
    configs_type::iterator const found =
        std::find_if(m_configs_lru.begin(), m_configs_lru.end(), string_prdicate(config));
    if (found != m_configs_lru.end())
    {
        configs_type::value_type temp = *found;
        m_configs_lru.erase(found);
        m_configs_lru.insert(m_configs_lru.begin(), std::make_pair(temp.first, temp.second));
        return temp.second;
    }

    string_path file_name;
    FS.update_path(file_name, "$game_config$", config.c_str());
    if (!FS.exist(file_name))
        return 0;

    m_configs_lru.insert(m_configs_lru.begin(), std::make_pair(config, FS.r_open(file_name)));
    return m_configs_lru.front().second;
}

namespace detail
{
bool object_exists_in_alife_registry(u32 id)
{
    if (ai().get_alife())
    {
        return ai().alife().objects().object((ALife::_OBJECT_ID)id, true) != 0;
    }
    return false;
}

} // detail
