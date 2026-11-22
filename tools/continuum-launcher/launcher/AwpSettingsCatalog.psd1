@{
    Settings = @(
        @{ Key='vid_mode'; Group='Display'; Kind='Resolution'; Label='Resolution'; Default=''; Help='Enter width x height, optionally followed by the refresh rate, for example 1920x1080 (144Hz). Leaving off the refresh rate keeps the current rate.' }
        @{ Key='vid_window_mode'; Group='Display'; Kind='Choice'; Label='Display mode'; Default='st_opt_windowed_borderless'; Choices=@(
            @('st_opt_windowed','Windowed'), @('st_opt_windowed_borderless','Borderless window'),
            @('st_opt_fullscreen','Fullscreen'), @('st_opt_fullscreen_borderless','Borderless fullscreen')
        ) }
        @{ Key='renderer'; Group='Display'; Kind='RuntimeChoice'; Label='Graphics renderer'; Choices=@(
            @('renderer_r4','DirectX 11'),@('renderer_rgl','OpenGL'),@('renderer_r3','DirectX 10'),
            @('renderer_r2.5','Enhanced DirectX 9 compatibility'),@('renderer_r2','DirectX 9 compatibility')
        ); Help='Available modes come from the last game startup on this installation.' }
        @{ Key='rs_fps_limit'; Group='Display'; Kind='Integer'; Label='Gameplay FPS cap'; Min=30; Max=501; Default='501' }
        @{ Key='rs_fps_limit_in_menu'; Group='Display'; Kind='Integer'; Label='Menu FPS cap'; Min=30; Max=501 }
        @{ Key='rs_v_sync'; Group='Display'; Kind='Toggle'; Label='Vertical sync'; Default='off' }
        @{ Key='rs_fps'; Group='Display'; Kind='Toggle'; Label='Show FPS counter' }
        @{ Key='rs_fps_graph'; Group='Display'; Kind='Toggle'; Label='Show frame-time graph' }
        @{ Key='rs_c_brightness'; Group='Display'; Kind='Number'; Label='Brightness'; Min=0.5; Max=1.5 }
        @{ Key='rs_c_contrast'; Group='Display'; Kind='Number'; Label='Contrast'; Min=0.5; Max=1.5 }
        @{ Key='rs_c_gamma'; Group='Display'; Kind='Number'; Label='Gamma'; Min=0.5; Max=1.5 }

        @{ Key='r2_ls_bloom_kernel_scale'; Group='Graphics'; Kind='Number'; Label='Bloom intensity'; Min=0.5; Max=2.0; Default='0.7' }
        @{ Key='texture_lod'; Group='Graphics'; Kind='Choice'; Label='Texture quality'; Choices=@(@('0','Highest'),@('1','High'),@('2','Medium'),@('3','Low'),@('4','Lowest')) }
        @{ Key='r__tf_aniso'; Group='Graphics'; Kind='Integer'; Label='Anisotropic filtering'; Min=1; Max=16 }
        @{ Key='r__geometry_lod'; Group='Graphics'; Kind='Number'; Label='Object detail'; Min=0.1; Max=2.0 }
        @{ Key='rs_vis_distance'; Group='Graphics'; Kind='Number'; Label='View distance multiplier'; Min=0.4; Max=1.5 }
        @{ Key='rs_detail'; Group='Graphics'; Kind='Toggle'; Label='Draw detail vegetation' }
        @{ Key='r__detail_density'; Group='Graphics'; Kind='Number'; Label='Grass density'; Min=0.1; Max=0.99; Help='Lower values space grass instances closer together.' }
        @{ Key='r__detail_radius'; Group='Graphics'; Kind='Integer'; Label='Grass draw radius'; Min=49; Max=300 }
        @{ Key='r__detail_height'; Group='Graphics'; Kind='Number'; Label='Grass height'; Min=1; Max=2 }
        @{ Key='r2_detail_bump'; Group='Graphics'; Kind='Toggle'; Label='Detail bump maps' }
        @{ Key='r2_steep_parallax'; Group='Graphics'; Kind='Toggle'; Label='Parallax mapping' }
        @{ Key='r2_ls_squality'; Group='Graphics'; Kind='Number'; Label='Dynamic light quality'; Min=0.5; Max=1 }
        @{ Key='r2_slight_fade'; Group='Graphics'; Kind='Number'; Label='Light fade distance'; Min=0.2; Max=1 }
        @{ Key='r2_smap_size'; Group='Graphics'; Kind='Choice'; Label='Shadow map resolution'; Choices=@(
            @('1024','1024'),@('1032','1032'),@('1536','1536'),@('2048','2048'),@('2560','2560'),@('3072','3072'),
            @('3584','3584'),@('4096','4096'),@('5120','5120'),@('6144','6144'),@('7168','7168'),
            @('8192','8192'),@('9216','9216'),@('10240','10240'),@('11264','11264'),@('12288','12288'),
            @('13312','13312'),@('14336','14336'),@('15360','15360'),@('16384','16384')
        ) }
        @{ Key='r2_sun_quality'; Group='Graphics'; Kind='Choice'; Label='Sun shadow quality'; Choices=@(
            @('st_opt_low','Low'),@('st_opt_medium','Medium'),@('st_opt_high','High'),@('st_opt_ultra','Ultra'),@('st_opt_extreme','Extreme')
        ); Help='Ultra and Extreme require DirectX 11.' }
        @{ Key='r2_sun_details'; Group='Graphics'; Kind='Toggle'; Label='Sun shadows on detail vegetation' }
        @{ Key='r2_sun_shafts'; Group='Graphics'; Kind='Choice'; Label='Sun shafts'; Choices=@(@('st_opt_off','Off'),@('st_opt_low','Low'),@('st_opt_medium','Medium'),@('st_opt_high','High')) }
        @{ Key='r__actor_shadow'; Group='Graphics'; Kind='Toggle'; Label='Player shadow' }
        @{ Key='r2_ssao_mode'; Group='Graphics'; Kind='Choice'; Label='Ambient occlusion algorithm'; Choices=@(
            @('disabled','Off'),@('default','Default'),@('hdao','HDAO'),@('hbao','HBAO')
        ) }
        @{ Key='r2_ssao'; Group='Graphics'; Kind='Choice'; Label='Ambient occlusion quality'; Choices=@(
            @('st_opt_off','Off'),@('st_opt_low','Low'),@('st_opt_medium','Medium'),@('st_opt_high','High'),@('st_opt_ultra','Ultra')
        ) }
        @{ Key='r3_msaa'; Group='Graphics'; Kind='Choice'; Label='Multisample anti-aliasing'; Choices=@(@('st_opt_off','Off'),@('2x','2x'),@('4x','4x'),@('8x','8x')) }
        @{ Key='r3_msaa_alphatest'; Group='Graphics'; Kind='Choice'; Label='Transparency anti-aliasing'; Choices=@(
            @('st_opt_off','Off'),@('st_opt_atest_msaa_dx10_0','Standard'),@('st_opt_atest_msaa_dx10_1','Higher quality')
        ); Help='This option takes effect when multisample anti-aliasing is enabled.' }
        @{ Key='r3_water_refl'; Group='Graphics'; Kind='Choice'; Label='Water reflection quality'; Choices=@(
            @('st_opt_off','Off'),@('st_opt_low','Low'),@('st_opt_medium','Medium'),@('st_opt_high','High'),@('st_opt_ultra','Ultra')
        ) }
        @{ Key='r2_dof_enable'; Group='Graphics'; Kind='Toggle'; Label='Depth of field' }
        @{ Key='r2_soft_particles'; Group='Graphics'; Kind='Toggle'; Label='Soft particles' }
        @{ Key='r2_soft_water'; Group='Graphics'; Kind='Toggle'; Label='Soft water edges' }
        @{ Key='r2_volumetric_lights'; Group='Graphics'; Kind='Toggle'; Label='Volumetric lighting' }
        @{ Key='r3_volumetric_smoke'; Group='Graphics'; Kind='Toggle'; Label='Volumetric smoke' }
        @{ Key='r3_dynamic_wet_surfaces'; Group='Graphics'; Kind='Toggle'; Label='Dynamic wet surfaces' }
        @{ Key='r4_enable_tessellation'; Group='Graphics'; Kind='Toggle'; Label='DirectX 11 tessellation'; Renderers=@('renderer_r4') }
        @{ Key='ai_use_torch_dynamic_lights'; Group='Graphics'; Kind='Toggle'; Label='NPC flashlight lighting' }
        @{ Key='r__wallmarks_on_skeleton'; Group='Graphics'; Kind='Switch'; Label='Decals on characters' }

        @{ Key='snd_volume_eff'; Group='Audio'; Kind='Number'; Label='Effects volume'; Min=0; Max=1; Default='1' }
        @{ Key='snd_volume_music'; Group='Audio'; Kind='Number'; Label='Music volume'; Min=0; Max=1; Default='1' }
        @{ Key='snd_device'; Group='Audio'; Kind='RuntimeChoice'; Label='Sound output device'; Help='Available devices come from the last game startup on this installation.' }
        @{ Key='snd_efx'; Group='Audio'; Kind='Toggle'; Label='Environmental audio effects (EFX)' }
        @{ Key='snd_use_float32'; Group='Audio'; Kind='Toggle'; Label='32-bit floating-point audio'; Help='Requires playback support from the OpenAL device.' }
        @{ Key='g_menu_clicks'; Group='Audio'; Kind='Toggle'; Label='Menu click sounds' }
        @{ Key='g_dynamic_music'; Group='Audio'; Kind='Toggle'; Label='Dynamic music' }

        @{ Key='mouse_sens'; Group='Controls'; Kind='Number'; Label='Mouse sensitivity'; Min=0.001; Max=0.6; Default='0.12' }
        @{ Key='mouse_sens_aim'; Group='Controls'; Kind='Number'; Label='Aiming sensitivity multiplier'; Min=0.1; Max=2 }
        @{ Key='mouse_invert'; Group='Controls'; Kind='Toggle'; Label='Invert vertical mouse movement' }
        @{ Key='g_normalize_mouse_sens'; Group='Controls'; Kind='Switch'; Label='Normalize sensitivity across zoom levels' }
        @{ Key='wpn_aim_toggle'; Group='Controls'; Kind='Switch'; Label='Toggle aiming' }
        @{ Key='g_crouch_toggle'; Group='Controls'; Kind='Toggle'; Label='Toggle crouching' }
        @{ Key='g_sprint_toggle'; Group='Controls'; Kind='Toggle'; Label='Toggle sprinting' }
        @{ Key='head_bob_factor'; Group='Controls'; Kind='Number'; Label='Head bob strength'; Min=0; Max=2 }
        @{ Key='fov'; Group='Controls'; Kind='Number'; Label='Camera field of view'; Min=5; Max=180 }
        @{ Key='hud_fov'; Group='Controls'; Kind='Number'; Label='Weapon field of view'; Min=0.1; Max=1 }
        @{ Key='scope_fov'; Group='Controls'; Kind='Number'; Label='Scope field of view multiplier'; Min=0.45; Max=0.85 }

        @{ Key='hud_crosshair'; Group='HUD'; Kind='Toggle'; Label='Show normal reticle'; Default='off'; Help='Controls the normal view reticle.' }
        @{ Key='cl_dynamiccrosshair'; Group='HUD'; Kind='Toggle'; Label='Dynamic reticle' }
        @{ Key='mode_crosshair'; Group='HUD'; Kind='Choice'; Label='Reticle motion'; Choices=@(
            @('standart_crosshair','Standard'),@('collide_crosshair','Collision'),@('inertion_crosshair','Inertia')
        ) }
        @{ Key='type_crosshair'; Group='HUD'; Kind='Choice'; Label='Reticle style'; Choices=@(
            @('type_crosshair_0','Style 1'),@('type_crosshair_1','Style 2'),@('type_crosshair_2','Style 3'),@('type_crosshair_3','Style 4')
        ) }
        @{ Key='hud_crosshair_dist'; Group='HUD'; Kind='Toggle'; Label='Show target distance' }
        @{ Key='hud_draw'; Group='HUD'; Kind='Toggle'; Label='Draw HUD' }
        @{ Key='hud_info'; Group='HUD'; Kind='Toggle'; Label='Show HUD information' }
        @{ Key='hud_weapon'; Group='HUD'; Kind='Toggle'; Label='Show weapon view model' }
        @{ Key='hud_left_handed'; Group='HUD'; Kind='Toggle'; Label='Left-handed weapon view' }
        @{ Key='hud_binocular_vision'; Group='HUD'; Kind='Toggle'; Label='Show binocular target markers' }
        @{ Key='hud_disable_minimap'; Group='HUD'; Kind='Toggle'; Label='Hide minimap' }
        @{ Key='rs_minimap_zoom_factor'; Group='HUD'; Kind='Number'; Label='Minimap zoom'; Min=0.3; Max=3 }
        @{ Key='minimap_alpha'; Group='HUD'; Kind='Integer'; Label='Minimap opacity'; Min=0; Max=255 }

        @{ Key='g_game_difficulty'; Group='Gameplay'; Kind='Choice'; Label='Difficulty'; Choices=@(
            @('gd_novice','Novice'),@('gd_stalker','Stalker'),@('gd_veteran','Veteran'),@('gd_master','Master')
        ) }
        @{ Key='g_important_save'; Group='Gameplay'; Kind='Toggle'; Label='Autosave at important events' }
        @{ Key='g_first_person_death'; Group='Gameplay'; Kind='Switch'; Label='First-person death camera' }
        @{ Key='g_use_tracers'; Group='Gameplay'; Kind='Toggle'; Label='Visible bullet tracers' }
        @{ Key='g_autopickup'; Group='Gameplay'; Kind='Toggle'; Label='Automatic pickup' }
        @{ Key='g_multi_item_pickup'; Group='Gameplay'; Kind='Toggle'; Label='Pick up multiple items together' }
        @{ Key='g_inv_highlight_equipped'; Group='Gameplay'; Kind='Switch'; Label='Highlight equipped items in inventory' }
        @{ Key='g_unload_ammo_after_pick_up'; Group='Gameplay'; Kind='Switch'; Label='Unload picked-up weapons automatically' }
    )
}
