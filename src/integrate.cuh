/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/


#pragma once
#include "common.cuh"


class Integrate 
{
public:
    Ensemble *ensemble; 
    Integrate(void);
    ~Integrate(void);   
    void initialize(Atom*);
    void finalize(void);
    void compute(Atom*, Force*, Measure*);

    // these data will be used to initialize ensemble
    int type;          // ensemble type in a specific run
    int source;
    int sink;
    real temperature;  // target temperature at a specific time 
    real delta_temperature;
    real pressure_x;   // target pressure at a specific time
    real pressure_y;   
    real pressure_z; 
    real temperature_coupling;
    real pressure_coupling; 
    int deform_x = 0;
    int deform_y = 0;
    int deform_z = 0;
    real deform_rate;
};


