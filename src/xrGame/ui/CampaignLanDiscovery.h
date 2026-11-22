#pragma once

#include <string>
#include <vector>

struct CampaignLanHost
{
    std::string address;
    std::string map;
    std::string mapVersion;
    unsigned port = 0;
    unsigned players = 0;
    unsigned capacity = 0;
    unsigned latency = 0;
};

std::vector<CampaignLanHost> DiscoverCampaignLanHosts();
