Shader "WindyGrass"
{
    //IMPORTANT
    //even though I struggled a lot doing this shader, Im aware that it's really basic. Plus I cannot assume that I did it ALL by myself.
    //I understood most of it but some parts are still too advanced and hard to comprehend for me. 
    //I will link the following sources I used:
    //(there are still some sources in some other comments that you can find below, but those are the main ones)
    //mainly followed Roystan's grass shader logic :https://roystan.net/articles/grass-shader/
    //inspired by Acerola's many grass videos: https://www.youtube.com/@Acerola_t
    //also followed logic from Binary Lunar: https://www.youtube.com/@BinaryLunar and Daniel Ilett https://www.youtube.com/@danielilett
    //solved some issues by following Valorexe's logic: https://github.com/Velorexe/unity-geometry-grass-shader

    //BUGS :)
    //I still dont understand why when I move the plane the grass has a weird offset, it's either related when i transform from object to wrold or to clip space
    //or I also have doubts about the wind velocity, anyways im happy with the result
    //The wind is also wery sketchy, like it works but not as I expected

    Properties
    {
        

        [Header(COLORS)]
        [Space]
        _Albedo("Albedo", Color) = (1, 1, 1, 1)//bottom color
        _Albedo2("Albedo2", Color) = (1, 1, 1, 1)//top color

        [Header(GRASS)]
        [Space]
        _GrassWidthHeightRange("Grass Width and Height Range", Vector) = (1,1,1,0) //x -> width min, y -> width max, z -> height min, w -> height max
        _GrassParams("Grass Params", Vector) = (1,1,1) //x -> bend curve, y -> bend distance, z -> grass amount (tesselation)

        [Header(WIND)]
        [Space]
        _WindParams("Wind Velocity and Frequency", Vector) = (1, 0, 0, 0)//x -> velocity.x, y -> velocity.y, z -> velocity.z, w -> frequency

        [Header(TEXTURES)]
        [Space]
        [NoScaleOffset]_GrassTex("Grass Tex", 2D) = "white" {}
        _WindNormalTex("Wind Normal Tex", 2D) = "bump" {}
    }

    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            "Queue" = "Geometry"
            "RenderPipeline" = "UniversalPipeline"
        }
        LOD 100
        Cull Off

        HLSLINCLUDE
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _SHADOWS_SOFT

            #define UNITY_PI 3.14159265359f
            #define UNITY_TWO_PI 6.28318530718f
            #define BLADE_SEGMENTS 4
            
            CBUFFER_START(UnityPerMaterial)
                sampler2D _GrassTex;
                sampler2D _WindNormalTex;

                float4 _Albedo;
                float4 _Albedo2;

                float4 _GrassWidthHeightRange;
                float3 _GrassParams;

                float4 _WindNormalTex_ST;//scale and tiling
                float4 _WindParams;
            CBUFFER_END

            struct VertexInput
            {
                float4 vertex  : POSITION;
                float3 normal  : NORMAL;
                float4 tangent : TANGENT;
                float2 uv      : TEXCOORD0;
            };

            struct VertexOutput
            {
                float4 vertex  : SV_POSITION;
                float3 normal  : NORMAL;
                float4 tangent : TANGENT;
                float2 uv      : TEXCOORD0;
            };

            struct TesselationParams
            {
                float edge[3] : SV_TessFactor;
                float inside  : SV_InsideTessFactor;
            };

            struct Geometry
            {
                float4 pos : SV_POSITION;
                float2 uv  : TEXCOORD0;
                float3 worldPos : TEXCOORD1;
            };

            //noise function
            float rand(float3 co)
            {
                return frac(sin(dot(co.xyz, float3(12.56, 56.65, 93.539))) * 5000.287);//basically random numbers
            }

            //rotation matrix
            //This is one of the many things that I would have struggle making it myself cause I have a small brain
            //source: https://gist.github.com/keijiro/ee439d5e7388f3aafc5296005c8c3f33
            float3x3 angleAxis3x3(float angle, float3 axis)
            {
                float c, s;
                sincos(angle, s, c);

                float t = 1 - c;
                float x = axis.x;
                float y = axis.y;
                float z = axis.z;

                return float3x3
                (
                    t * x * x + c, t * x * y - s * z, t * x * z + s * y,
                    t * x * y + s * z, t * y * y + c, t * y * z - s * x,
                    t * x * z - s * y, t * y * z + s * x, t * z * z + c
                );
            }

            //regular vertex shader
            VertexOutput vert(VertexInput v)
            {
                VertexOutput o;
                o.vertex = TransformObjectToHClip(v.vertex.xyz);
                o.normal = v.normal;
                o.tangent = v.tangent;
                o.uv = TRANSFORM_TEX(v.uv, _WindNormalTex);
                return o;
            }

            //vertex shader for tessellation
            VertexOutput tessVert(VertexInput v)
            {
                VertexOutput o;
                o.vertex = v.vertex;
                o.normal = v.normal;
                o.tangent = v.tangent;
                o.uv = v.uv;
                return o;
            }

            //vertex shader object->world
            VertexOutput geomVert (VertexInput v)
            {
                VertexOutput o; 
                o.vertex = float4(TransformObjectToWorld(v.vertex), 1.0f);
                o.normal = TransformObjectToWorldNormal(v.normal);
                o.tangent = v.tangent;
                o.uv = TRANSFORM_TEX(v.uv, _WindNormalTex);
                return o;
            }

            //tesselation for edge
            float tesselationForEdge(VertexInput vert0, VertexInput vert1)
            {
                float3 v0 = vert0.vertex.xyz;
                float3 v1 = vert1.vertex.xyz;
                float edgeLength = distance(v0, v1);
                return edgeLength / _GrassParams.z;
            }

            //increasing tesselation for edges and inside, this is from: https://www.youtube.com/@danielilett
            TesselationParams patchConstantFunc(InputPatch<VertexInput, 3> patch)
            {
                TesselationParams p;

                p.edge[0] = tesselationForEdge(patch[1], patch[2]);
                p.edge[1] = tesselationForEdge(patch[2], patch[0]);
                p.edge[2] = tesselationForEdge(patch[0], patch[1]);
                p.inside = (p.edge[0] + p.edge[1] + p.edge[2]) / 3.0f;

                return p;
            }

            [domain("tri")]
            [outputcontrolpoints(3)]
            [outputtopology("triangle_cw")]
            [partitioning("integer")]
            [patchconstantfunc("patchConstantFunc")]
            VertexInput hull(InputPatch<VertexInput, 3> patch, uint id : SV_OutputControlPointID)
            {
                return patch[id];
            }

            [domain("tri")]
            VertexOutput domain(TesselationParams params, OutputPatch<VertexInput, 3> patch, float3 barycentricCoordinates : SV_DomainLocation)
            {
                VertexInput i;

                #define INTERPOLATE(fieldname) i.fieldname = \
                    patch[0].fieldname * barycentricCoordinates.x + \
                    patch[1].fieldname * barycentricCoordinates.y + \
                    patch[2].fieldname * barycentricCoordinates.z;

                INTERPOLATE(vertex)
                INTERPOLATE(normal)
                INTERPOLATE(tangent)
                INTERPOLATE(uv)

                return tessVert(i);
            }

            //convert to clip space
            Geometry TransformGeomToClip(float3 pos, float3 offset, float3x3 transformationMatrix, float2 uv)
            {
                Geometry o;

                o.pos = TransformObjectToHClip(pos + mul(transformationMatrix, offset));
                o.uv = uv;
                o.worldPos = TransformObjectToWorld(pos + mul(transformationMatrix, offset));

                return o;
            }

            //geometry shader
            [maxvertexcount(BLADE_SEGMENTS * 2 + 1)]
            void geom(point VertexOutput input[1], inout TriangleStream<Geometry> triStream)
            {
                float3 pos = input[0].vertex.xyz;

                float3 normal = input[0].normal;
                float4 tangent = input[0].tangent;
                float3 bitangent = cross(normal, tangent.xyz) * tangent.w;

                float3x3 tangentToLocal = float3x3
                (
                    tangent.x, bitangent.x, normal.x,
                    tangent.y, bitangent.y, normal.y,
                    tangent.z, bitangent.z, normal.z
                );

                float3x3 randomMatrixRotation = angleAxis3x3(rand(pos) * UNITY_TWO_PI, float3(0, 0, 1.0f));
                float3x3 randomMatrixBend = angleAxis3x3(rand(pos.zzx) * _GrassParams.x * UNITY_PI * 0.5f, float3(-1.0f, 0, 0));

                float2 windUV = pos.xz * _WindNormalTex_ST.xy + _WindNormalTex_ST.zw + normalize(_WindParams.xzy) * _WindParams.w * _Time.y;
                float2 sampledWind = (tex2Dlod(_WindNormalTex, float4(windUV, 0, 0)).xy * 2 - 1) * length(_WindParams);
                float3 windAxes = normalize(float3(sampledWind.x, sampledWind.y, 0));
                float3x3 windMatrix = angleAxis3x3(UNITY_PI * sampledWind, windAxes);

                float3x3 botMatrixTransform = mul(tangentToLocal, randomMatrixRotation);
                float3x3 topMatrixTransform = mul(mul(mul(tangentToLocal, windMatrix), randomMatrixBend), randomMatrixRotation);

                float width  = lerp(_GrassWidthHeightRange.x, _GrassWidthHeightRange.y, rand(pos.xzy));
                float height = lerp(_GrassWidthHeightRange.z, _GrassWidthHeightRange.w, rand(pos.zyx));
                float forward = rand(pos.yyz) * _GrassParams.y;

                //create blades
                for (int i = 0; i < BLADE_SEGMENTS; ++i)
                {
                    float t = i / (float)BLADE_SEGMENTS;
                    float3 offset = float3(width * (1 - t), pow(t, _GrassParams.y) * forward, height * t);

                    float3x3 transformationMatrix = (i == 0) ? botMatrixTransform : topMatrixTransform;
                                                                                                                            //also preparing the uvs here in the end
                    triStream.Append(TransformGeomToClip(pos, float3( offset.x, offset.y, offset.z), transformationMatrix, float2(0, t)));
                    triStream.Append(TransformGeomToClip(pos, float3(-offset.x, offset.y, offset.z), transformationMatrix, float2(1, t)));
                }

                triStream.Append(TransformGeomToClip(pos, float3(0, forward, height), topMatrixTransform, float2(0.5, 1)));

                triStream.RestartStrip();
            }
        ENDHLSL

        //rendering grass
        Pass
        {
            Name "GrassPass"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma require geometry
            #pragma require tessellation tessHW

            #pragma vertex geomVert
            #pragma hull hull
            #pragma domain domain
            #pragma geometry geom
            #pragma fragment frag

            half4 frag(Geometry i) : SV_Target
            {
                float4 color = tex2D(_GrassTex, i.uv);

                #ifdef _MAIN_LIGHT_SHADOWS
                VertexPositionInputs vertexInput = (VertexPositionInputs)0;
                vertexInput.positionWS = i.worldPos;

                float4 shadowCoord = GetShadowCoord(vertexInput);
                half shadowAttenuation = saturate(MainLightRealtimeShadow(shadowCoord) + 0.25f);
                float4 shadowColor = lerp(0.0f, 1.0f, shadowAttenuation);
                color *= shadowColor;
                #endif

                return color * lerp(_Albedo, _Albedo2, i.uv.y);
            }

            ENDHLSL
        }
    }
    FallBack "Diffuse"
}
