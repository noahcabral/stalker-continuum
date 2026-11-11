#include "StdAfx.h"
#include "game_sv_single.h"
#include "xrServer_Objects_ALife_Monsters.h"
#include "alife_simulator.h"
#include "alife_object_registry.h"
#include "alife_graph_registry.h"
#include "alife_time_manager.h"
#include "Common/object_broker.h"
#include "GamePersistent.h"
#include "Level.h"
#include "xrAICore/Navigation/level_graph.h"
#include "xrAICore/Navigation/game_graph.h"
#include "xrServer.h"

game_sv_Single::game_sv_Single()
{
    m_alife_simulator = NULL;
    m_type = eGameIDSingle;
};

game_sv_Single::~game_sv_Single() { delete_data(m_alife_simulator); }
void game_sv_Single::Create(shared_str& options)
{
    inherited::Create(options);
    m_guestStartSection = get_option_s(options.c_str(), "guest_start", "");
    if (strstr(options.c_str(), "/alife"))
    {
        Level().PrepareCampaignState();
        m_alife_simulator = xr_new<CALifeSimulator>(&server(), &options);
    }
    switch_Phase(GAME_PHASE_INPROGRESS);
}

/**
CSE_Abstract*		game_sv_Single::get_entity_from_eid		(u16 id)
{
    if (!ai().get_alife())
        return			(inherited::get_entity_from_eid(id));

    CSE_Abstract		*object = ai().alife().objects().object(id,true);
    if (!object)
        return			(inherited::get_entity_from_eid(id));

    return				(object);
}
**/

void game_sv_Single::OnPlayerConnect(ClientID id)
{
    inherited::OnPlayerConnect(id);
    auto* client = server().ID_to_client(id);
    if (!m_alife_simulator || !client || client == server().GetServerClient() || client->owner)
        return;

    auto* campaignActor = alife().graph().actor();
    if (!campaignActor)
        return;

    auto* player = static_cast<CSE_ALifeCreatureActor*>(spawn_begin("actor"));
    player->set_specific_character(campaignActor->specific_character());
    player->set_name_replace(client->ps->getName());
    player->s_flags.assign(M_SPAWN_OBJECT_LOCAL | M_SPAWN_OBJECT_ASPLAYER | M_SPAWN_OBJECT_CAMPAIGN_PLAYER);
    player->o_Position = campaignActor->o_Position;
    player->o_Angle = campaignActor->o_Angle;
    player->m_tNodeID = campaignActor->m_tNodeID;
    player->m_tGraphID = campaignActor->m_tGraphID;
    if (ai().get_level_graph())
    {
        const auto& graph = ai().level_graph();
        if (m_guestStartSection.size())
        {
            string_path path;
            FS.update_path(path, "$game_config$", R"(plugins\new_game_start_locations.ltx)");
            if (FS.exist(path))
            {
                const CInifile starts(path);
                const char* section = m_guestStartSection.c_str();
                if (starts.section_exist(section))
                {
                    const auto vertex = starts.r_u32(section, "lvid");
                    const auto gameVertex = starts.r_u32(section, "gvid");
                    if (graph.valid_vertex_id(vertex) && ai().game_graph().valid_vertex_id(gameVertex) &&
                        ai().game_graph().vertex(gameVertex)->level_id() == graph.level_id())
                    {
                        const Fvector start = Fvector().set(starts.r_float(section, "x"),
                            starts.r_float(section, "y"), starts.r_float(section, "z"));
                        const auto actualVertex = graph.vertex(vertex, start);
                        if (graph.valid_vertex_id(actualVertex))
                        {
                            player->m_tNodeID = actualVertex;
                            player->m_tGraphID = ai().cross_table().vertex(actualVertex).game_vertex_id();
                            player->o_Position = graph.vertex_position(actualVertex);
                        }
                    }
                }
            }
        }

        const u32 clients = server().GetClientsCount();
        if (clients > 2)
        {
            const u32 slot = clients - 3;
            const Fvector origin = player->o_Position;
            const float radius = 1.75f * (1.f + static_cast<float>(slot / 6));
            for (u32 attempt = 0; attempt < 6; ++attempt)
            {
                const float angle = static_cast<float>((slot + attempt) % 6) * (PI / 3.f);
                Fvector nearby = origin;
                nearby.x += radius * std::cos(angle);
                nearby.z += radius * std::sin(angle);
                const auto vertex = graph.vertex(player->m_tNodeID, nearby);
                if (!graph.valid_vertex_id(vertex))
                    continue;

                const Fvector candidate = graph.vertex_position(vertex);
                if (std::abs(candidate.y - origin.y) > 0.7f || candidate.distance_to(origin) < 0.85f)
                    continue;

                player->m_tNodeID = vertex;
                player->o_Position = candidate;
                player->m_tGraphID = ai().cross_table().vertex(vertex).game_vertex_id();
                break;
            }
        }
    }

    if (const auto* actor = spawn_end(player, id))
    {
        client->ps->GameID = actor->ID;
        Msg("* Campaign guest actor %u assigned", actor->ID);
    }
}

void game_sv_Single::OnCreate(u16 id_who)
{
    if (!ai().get_alife())
        return;

    CSE_Abstract* e_who = get_entity_from_eid(id_who);
    VERIFY(e_who);
    if (e_who->s_flags.is(M_SPAWN_OBJECT_ASPLAYER) && e_who->owner &&
        e_who->owner != server().GetServerClient())
    {
        e_who->m_bALifeControl = false;
        return;
    }
    if (!e_who->m_bALifeControl)
        return;

    CSE_ALifeObject* alife_object = smart_cast<CSE_ALifeObject*>(e_who);
    if (!alife_object)
        return;

    alife_object->m_bOnline = true;

    if (alife_object->ID_Parent != 0xffff)
    {
        CSE_ALifeDynamicObject* parent = ai().alife().objects().object(alife_object->ID_Parent, true);
        if (parent)
        {
            CSE_ALifeTraderAbstract* trader = smart_cast<CSE_ALifeTraderAbstract*>(parent);
            if (trader)
                alife().create(alife_object);
            else
            {
                CSE_ALifeInventoryBox* const box = smart_cast<CSE_ALifeInventoryBox*>(parent);
                if (box)
                    alife().create(alife_object);
                else
                    alife_object->m_bALifeControl = false;
            }
        }
        else
            alife_object->m_bALifeControl = false;
    }
    else
        alife().create(alife_object);
}

BOOL game_sv_Single::OnTouch(u16 eid_who, u16 eid_what, BOOL bForced)
{
    CSE_Abstract* e_who = get_entity_from_eid(eid_who);
    VERIFY(e_who);
    CSE_Abstract* e_what = get_entity_from_eid(eid_what);
    VERIFY(e_what);

    if (ai().get_alife())
    {
        CSE_ALifeInventoryItem* l_tpALifeInventoryItem = smart_cast<CSE_ALifeInventoryItem*>(e_what);
        CSE_ALifeDynamicObject* l_tpDynamicObject = smart_cast<CSE_ALifeDynamicObject*>(e_who);

        if (l_tpALifeInventoryItem && l_tpDynamicObject &&
            ai().alife().graph().level().object(l_tpALifeInventoryItem->base()->ID, true) &&
            ai().alife().objects().object(e_who->ID, true) && ai().alife().objects().object(e_what->ID, true))
            alife().graph().attach(*e_who, l_tpALifeInventoryItem, l_tpDynamicObject->m_tGraphID, false, false);
#ifdef DEBUG
        else if (psAI_Flags.test(aiALife))
        {
            Msg("Cannot attach object [%s][%s][%d] to object [%s][%s][%d]", e_what->name_replace(), e_what->s_name.c_str(),
                e_what->ID, e_who->name_replace(), e_who->s_name.c_str(), e_who->ID);
        }
#endif
    }
    return TRUE;
}

void game_sv_Single::OnDetach(u16 eid_who, u16 eid_what)
{
    if (ai().get_alife())
    {
        CSE_Abstract* e_who = get_entity_from_eid(eid_who);
        VERIFY(e_who);
        CSE_Abstract* e_what = get_entity_from_eid(eid_what);
        VERIFY(e_what);

        CSE_ALifeInventoryItem* l_tpALifeInventoryItem = smart_cast<CSE_ALifeInventoryItem*>(e_what);
        if (!l_tpALifeInventoryItem)
            return;

        CSE_ALifeDynamicObject* l_tpDynamicObject = smart_cast<CSE_ALifeDynamicObject*>(e_who);
        if (!l_tpDynamicObject)
            return;

        if (ai().alife().objects().object(e_who->ID, true) &&
            !ai().alife().graph().level().object(l_tpALifeInventoryItem->base()->ID, true) &&
            ai().alife().objects().object(e_what->ID, true))
            alife().graph().detach(*e_who, l_tpALifeInventoryItem, l_tpDynamicObject->m_tGraphID, false, false);
        else
        {
            if (!ai().alife().objects().object(e_what->ID, true))
            {
                u16 id = l_tpALifeInventoryItem->base()->ID_Parent;
                l_tpALifeInventoryItem->base()->ID_Parent = 0xffff;

                CSE_ALifeDynamicObject* dynamic_object = smart_cast<CSE_ALifeDynamicObject*>(e_what);
                VERIFY(dynamic_object);
                dynamic_object->m_tNodeID = l_tpDynamicObject->m_tNodeID;
                dynamic_object->m_tGraphID = l_tpDynamicObject->m_tGraphID;
                dynamic_object->m_bALifeControl = true;
                dynamic_object->m_bOnline = true;
                alife().create(dynamic_object);
                l_tpALifeInventoryItem->base()->ID_Parent = id;
            }
#ifdef DEBUG
            else if (psAI_Flags.test(aiALife))
            {
                Msg("Cannot detach object [%s][%s][%d] from object [%s][%s][%d]",
                    l_tpALifeInventoryItem->base()->name_replace(), l_tpALifeInventoryItem->base()->s_name.c_str(),
                    l_tpALifeInventoryItem->base()->ID, l_tpDynamicObject->base()->name_replace(),
                    l_tpDynamicObject->base()->s_name.c_str(), l_tpDynamicObject->ID);
            }
#endif
        }
    }
}

void game_sv_Single::Update()
{
    inherited::Update();
    /*	switch(phase) 	{
            case GAME_PHASE_PENDING : {
                OnRoundStart();
                switch_Phase(GAME_PHASE_INPROGRESS);
                break;
            }
        }*/
}

ALife::_TIME_ID game_sv_Single::GetStartGameTime()
{
    if (ai().get_alife() && ai().alife().initialized())
        return (ai().alife().time_manager().start_game_time());
    else
        return (inherited::GetStartGameTime());
}

ALife::_TIME_ID game_sv_Single::GetGameTime()
{
    if (ai().get_alife() && ai().alife().initialized())
        return (ai().alife().time_manager().game_time());
    else
        return (inherited::GetGameTime());
}

float game_sv_Single::GetGameTimeFactor()
{
    if (ai().get_alife() && ai().alife().initialized())
        return (ai().alife().time_manager().time_factor());
    else
        return (inherited::GetGameTimeFactor());
}

void game_sv_Single::SetGameTimeFactor(const float fTimeFactor)
{
    if (ai().get_alife() && ai().alife().initialized())
        return (alife().time_manager().set_time_factor(fTimeFactor));
    else
        return (inherited::SetGameTimeFactor(fTimeFactor));
}

void game_sv_Single::SetGameTimeFactor(ALife::_TIME_ID GameTime, const float fTimeFactor)
{
    if (ai().get_alife() && ai().alife().initialized())
        return (alife().time_manager().set_game_time_factor(GameTime, fTimeFactor));
    else
        return (inherited::SetGameTimeFactor(GameTime, fTimeFactor));
}

ALife::_TIME_ID game_sv_Single::GetEnvironmentGameTime()
{
    if (ai().get_alife() && ai().alife().initialized())
        return (alife().time_manager().game_time());
    else
        return (inherited::GetGameTime());
}

float game_sv_Single::GetEnvironmentGameTimeFactor() { return (inherited::GetGameTimeFactor()); }
void game_sv_Single::SetEnvironmentGameTimeFactor(const float fTimeFactor)
{
    return (inherited::SetGameTimeFactor(fTimeFactor));
}

bool game_sv_Single::change_level(NET_Packet& net_packet, ClientID sender)
{
    if (ai().get_alife())
        return (alife().change_level(net_packet));
    else
        return (true);
}

void game_sv_Single::save_game(NET_Packet& net_packet, ClientID sender)
{
    if (!ai().get_alife())
        return;

    alife().save(net_packet);
}

bool game_sv_Single::load_game(NET_Packet& net_packet, ClientID sender)
{
    if (!ai().get_alife())
        return (inherited::load_game(net_packet, sender));
    shared_str game_name;
    net_packet.r_stringZ(game_name);
    return (alife().load_game(game_name.c_str(), true));
}

void game_sv_Single::reload_game(NET_Packet& net_packet, ClientID sender) {}
void game_sv_Single::switch_distance(NET_Packet& net_packet, ClientID sender)
{
    if (!ai().get_alife())
        return;

    alife().set_switch_distance(net_packet.r_float());
}

void game_sv_Single::teleport_object(NET_Packet& net_packet, u16 id)
{
    if (!ai().get_alife())
        return;

    GameGraph::_GRAPH_ID game_vertex_id;
    u32 level_vertex_id;
    Fvector position;

    net_packet.r(&game_vertex_id, sizeof(game_vertex_id));
    net_packet.r(&level_vertex_id, sizeof(level_vertex_id));
    net_packet.r_vec3(position);

    alife().teleport_object(id, game_vertex_id, level_vertex_id, position);
}

void game_sv_Single::add_restriction(NET_Packet& packet, u16 id)
{
    if (!ai().get_alife())
        return;

    ALife::_OBJECT_ID restriction_id;
    packet.r(&restriction_id, sizeof(restriction_id));

    RestrictionSpace::ERestrictorTypes restriction_type;
    packet.r(&restriction_type, sizeof(restriction_type));

    alife().add_restriction(id, restriction_id, restriction_type);
}

void game_sv_Single::remove_restriction(NET_Packet& packet, u16 id)
{
    if (!ai().get_alife())
        return;

    ALife::_OBJECT_ID restriction_id;
    packet.r(&restriction_id, sizeof(restriction_id));

    RestrictionSpace::ERestrictorTypes restriction_type;
    packet.r(&restriction_type, sizeof(restriction_type));

    alife().remove_restriction(id, restriction_id, restriction_type);
}

void game_sv_Single::remove_all_restrictions(NET_Packet& packet, u16 id)
{
    if (!ai().get_alife())
        return;

    RestrictionSpace::ERestrictorTypes restriction_type;
    packet.r(&restriction_type, sizeof(restriction_type));

    alife().remove_all_restrictions(id, restriction_type);
}

void game_sv_Single::sls_default() { alife().update_switch(); }
shared_str game_sv_Single::level_name(const shared_str& server_options) const
{
    if (!ai().get_alife())
        return (inherited::level_name(server_options));
    return (alife().level_name());
}

void game_sv_Single::on_death(CSE_Abstract* e_dest, CSE_Abstract* e_src)
{
    inherited::on_death(e_dest, e_src);

    if (!ai().get_alife())
        return;

    alife().on_death(e_dest, e_src);
}

void game_sv_Single::restart_simulator(LPCSTR saved_game_name)
{
    shared_str& options = *alife().server_command_line();

    delete_data(m_alife_simulator);
    server().clear_ids();

    xr_strcpy(g_pGamePersistent->m_game_params.m_game_or_spawn, saved_game_name);
    xr_strcpy(g_pGamePersistent->m_game_params.m_new_or_load, "load");

    g_pGamePersistent->LoadBegin();
    m_alife_simulator = xr_new<CALifeSimulator>(&server(), &options);
    g_pGamePersistent->LoadTitle("st_client_synchronising");
    Device.PreCache(60, true);
    g_pGamePersistent->LoadEnd();
}
